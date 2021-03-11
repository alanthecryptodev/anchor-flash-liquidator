//SPDX-License-Identifier: None

pragma solidity ^0.8.0;

import "./interfaces/IERC3156FlashBorrower.sol";
import "./interfaces/IERC3156FlashLender.sol";
import "./interfaces/ICErc20.sol";
import "./interfaces/IWeth.sol";
import "./interfaces/IComptroller.sol";
import "./interfaces/IRouter.sol";
import "./utils/Ownable.sol";
import "./ERC20/IERC20.sol";
import "./ERC20/SafeERC20.sol";

contract AnchorFlashLiquidator is Ownable {
    using SafeERC20 for IERC20;

    IERC3156FlashLender public flashLender =
        IERC3156FlashLender(0x6bdC1FCB2F13d1bA9D26ccEc3983d5D4bf318693);
    IComptroller public comptroller =
        IComptroller(0x4dCf7407AE5C07f8681e1659f626E114A7667339);
    IRouter public constant sushiRouter =
        IRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    IRouter public constant uniRouter =
        IRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IWeth public constant weth =
        IWeth(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    struct LiquidationData {
        address cErc20;
        address underlying;
        address cTokenCollateral;
        address borrower;
        address caller;
        IRouter enterRouter;
        IRouter exitRouter;
        uint256 amountToRepay;
        uint256 minProfit;
        uint256 deadline;
    }

    receive() external payable {}

    fallback() external payable {}

    function liquidate(
        address _flashLoanToken,
        address _cErc20,
        address _borrower,
        address _cTokenCollateral,
        IRouter _enterRouter,
        IRouter _exitRouter,
        uint256 _minProfit,
        uint256 _deadline
    ) external {
        require(
            (_enterRouter == sushiRouter || _enterRouter == uniRouter) &&
                (_exitRouter == sushiRouter || _exitRouter == uniRouter),
            "Invalid router"
        );
        // make sure borrower is liquidatable
        (, , uint256 shortfall) = comptroller.getAccountLiquidity(_borrower);
        require(shortfall > 0, "!liquidatable");

        address _underlying = ICErc20(_cErc20).underlying();
        uint256 _amountToRepay =
            ICErc20(_cErc20).borrowBalanceStored(_borrower);
        uint256 _tokensNeeded;
        {
            // scope to avoid stack too deep error
            address[] memory path = _getPath(_flashLoanToken, _underlying);
            _tokensNeeded = _enterRouter.getAmountsIn(_amountToRepay, path)[0];
            require(
                _tokensNeeded <= flashLender.maxFlashLoan(_flashLoanToken),
                "Insufficient lender reserves"
            );
            uint256 _fee = flashLender.flashFee(_flashLoanToken, _tokensNeeded);
            uint256 repayment = _tokensNeeded + _fee;
            _approve(IERC20(_flashLoanToken), address(flashLender), repayment);
        }
        bytes memory data =
            abi.encode(
                LiquidationData({
                    cErc20: _cErc20,
                    underlying: _underlying,
                    cTokenCollateral: _cTokenCollateral,
                    borrower: _borrower,
                    caller: msg.sender,
                    enterRouter: _enterRouter,
                    exitRouter: _exitRouter,
                    amountToRepay: _amountToRepay,
                    minProfit: _minProfit,
                    deadline: _deadline
                })
            );
        flashLender.flashLoan(
            address(this),
            _flashLoanToken,
            _tokensNeeded,
            data
        );
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == address(flashLender), "Untrusted lender");
        require(initiator == address(this), "Untrusted loan initiator");
        LiquidationData memory liqData = abi.decode(data, (LiquidationData));

        // Step 1: Convert token to repay token
        _approve(IERC20(token), address(liqData.enterRouter), amount);
        address[] memory entryPath = _getPath(token, liqData.underlying);
        liqData.enterRouter.swapTokensForExactTokens(
            liqData.amountToRepay,
            type(uint256).max,
            entryPath,
            address(this),
            liqData.deadline
        );

        // Step 2: Liquidate borrower and seize their cToken
        _approve(
            IERC20(liqData.underlying),
            liqData.cErc20,
            liqData.amountToRepay
        );
        ICErc20(liqData.cErc20).liquidateBorrow(
            liqData.borrower,
            liqData.amountToRepay,
            liqData.cTokenCollateral
        );
        uint256 seizedBal =
            IERC20(liqData.cTokenCollateral).balanceOf(address(this));

        // Step 3: Redeem seized cTokens for collateral
        _approve(IERC20(liqData.cTokenCollateral), liqData.cErc20, seizedBal);
        uint256 ethBalBefore = address(this).balance; // snapshot ETH balance before redeem to determine if it is cEther
        ICErc20(liqData.cTokenCollateral).redeem(seizedBal);
        address underlying;

        // Step 3.1: Get amount of underlying collateral redeemed
        if (address(this).balance > ethBalBefore) {
            // If ETH balance increased, seized cToken is cEther
            // Wrap ETH into WETH
            weth.deposit{value: address(this).balance}();
            underlying = address(weth);
        } else {
            underlying = ICErc20(liqData.cTokenCollateral).underlying();
        }
        uint256 underlyingBal = IERC20(underlying).balanceOf(address(this));

        // Step 4: Swap underlying collateral for token (if collateral != token)
        uint256 tokensReceived;
        if (underlying != token) {
            _approve(
                IERC20(underlying),
                address(liqData.exitRouter),
                underlyingBal
            );
            address[] memory exitPath = _getPath(underlying, token);
            tokensReceived = liqData.exitRouter.swapExactTokensForTokens(
                underlyingBal,
                0,
                exitPath,
                address(this),
                liqData.deadline
            )[exitPath.length - 1];
        } else {
            tokensReceived = underlyingBal;
        }

        // Step 5: Sanity check to ensure process is profitable
        require(
            tokensReceived >= amount + fee + liqData.minProfit,
            "Not enough profit"
        );

        // Step 6: Send profits to caller
        IERC20(token).safeTransfer(
            liqData.caller,
            tokensReceived - (amount + fee)
        );
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function setFlashLender(IERC3156FlashLender _flashLender)
        external
        onlyOwner
    {
        flashLender = _flashLender;
    }

    function setComptroller(IComptroller _comptroller) external onlyOwner {
        comptroller = _comptroller;
    }

    function _getPath(address _tokenIn, address _tokenOut)
        internal
        pure
        returns (address[] memory path)
    {
        if (_tokenIn == address(weth)) {
            path = new address[](2);
            path[0] = address(weth);
            path[1] = _tokenOut;
        } else {
            path = new address[](3);
            path[0] = _tokenIn;
            path[1] = address(weth);
            path[2] = _tokenOut;
        }
    }

    function _approve(
        IERC20 _token,
        address _spender,
        uint256 _amount
    ) internal {
        if (_token.allowance(address(this), _spender) < _amount) {
            _token.safeApprove(_spender, type(uint256).max);
        }
    }
}
