pragma solidity ^0.8.0;

import "../ERC20/IERC20.sol";

interface IWeth is IERC20 {
    function deposit() external payable;
}
