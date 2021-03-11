pragma solidity ^0.8.0;

interface ICErc20 {
    function liquidateBorrow(address borrower, uint amount, address collateral) external returns (uint);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function underlying() external view returns (address);
}
