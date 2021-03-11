pragma solidity ^0.8.0;

interface IComptroller {
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}
