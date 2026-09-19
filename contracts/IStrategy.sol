// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IStrategy {
    function name() external view returns (string memory);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function harvest() external;
    function setKeeper(address keeper) external;
}
