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
    IERC20 public constant dola =
        IERC20(0x865377367054516e17014CcdED1e7d814EDC9ce4);
    IWeth public constant weth =
        IWeth(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant dai =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    struct LiquidationData {
        address cErc20;
        address cTokenCollateral;
        address borrower;
        address caller;
        IRouter dolaRouter;
        IRouter exitRouter;
        uint256 shortfall;
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
        IRouter _dolaRouter,
        IRouter _exitRouter,
        uint256 _minProfit,
        uint256 _deadline
    ) external {
        require(
            (_dolaRouter == sushiRouter || _dolaRouter == uniRouter) &&
                (_exitRouter == sushiRouter || _exitRouter == uniRouter),
            "Invalid router"
        );
        // make sure _borrower is liquidatable
        (, , uint256 shortfall) = comptroller.getAccountLiquidity(_borrower);
        require(shortfall > 0, "!liquidatable");
        address[] memory path = _getDolaPath(_flashLoanToken);
        uint256 tokensNeeded;
        {
            // scope to avoid stack too deep error
            tokensNeeded = _dolaRouter.getAmountsIn(shortfall, path)[0];
            require(
                tokensNeeded <= flashLender.maxFlashLoan(_flashLoanToken),
                "Insufficient lender reserves"
            );
            uint256 fee = flashLender.flashFee(_flashLoanToken, tokensNeeded);
            uint256 repayment = tokensNeeded + fee;
            _approve(IERC20(_flashLoanToken), address(flashLender), repayment);
        }
        bytes memory data =
            abi.encode(
                LiquidationData({
                    cErc20: _cErc20,
                    cTokenCollateral: _cTokenCollateral,
                    borrower: _borrower,
                    caller: msg.sender,
                    dolaRouter: _dolaRouter,
                    exitRouter: _exitRouter,
                    shortfall: shortfall,
                    minProfit: _minProfit,
                    deadline: _deadline
                })
            );
        flashLender.flashLoan(
            address(this),
            _flashLoanToken,
            tokensNeeded,
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

        // Step 1: Convert token to DOLA
        _approve(IERC20(token), address(liqData.dolaRouter), amount);
        address[] memory entryPath = _getDolaPath(token);
        liqData.dolaRouter.swapTokensForExactTokens(
            liqData.shortfall,
            type(uint256).max,
            entryPath,
            address(this),
            liqData.deadline
        );

        // Step 2: Liquidate borrower and seize their cToken
        _approve(dola, liqData.cErc20, liqData.shortfall);
        ICErc20(liqData.cErc20).liquidateBorrow(
            liqData.borrower,
            liqData.shortfall,
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
            address[] memory exitPath = _getExitPath(underlying, token);
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

    function _getDolaPath(address _token)
        internal
        pure
        returns (address[] memory path)
    {
        if (_token == address(weth)) {
            path = new address[](2);
            path[0] = address(weth);
            path[1] = address(dola);
        } else {
            path = new address[](3);
            path[0] = _token;
            path[1] = address(weth);
            path[2] = address(dola);
        }
    }

    function _getExitPath(address _underlying, address _token)
        internal
        pure
        returns (address[] memory path)
    {
        if (_underlying == address(weth)) {
            path = new address[](2);
            path[0] = address(weth);
            path[1] = _token;
        } else {
            path = new address[](3);
            path[0] = address(_underlying);
            path[1] = address(weth);
            path[2] = _token;
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
