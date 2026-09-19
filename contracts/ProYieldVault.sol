// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ProYieldVault is BaseStrategy {
    uint256 public performanceFee;
    uint256 public withdrawalFee;
    address public feeDistributor;
    mapping(address => bool) public strategies;
    uint256 public totalAssets;
    
    constructor(
        address _underlying, 
        address _owner,
        address _feeDistributor
    ) BaseStrategy(_underlying, _owner) {
        feeDistributor = _feeDistributor;
        performanceFee = 1000; // 10%
        withdrawalFee = 50; // 0.5%
    }

    function addStrategy(address _strategy) external onlyOwner {
        strategies[_strategy] = true;
    }

    function setPerformanceFee(uint256 _fee) external onlyOwner {
        performanceFee = _fee;
    }

    function emergencyWithdraw() external onlyOwner {
        uint256 balance = underlying.balanceOf(address(this));
        underlying.transfer(msg.sender, balance);
    }
}
