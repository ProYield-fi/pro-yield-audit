// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FeeDistributor is ReentrancyGuard, Ownable {
    IERC20 public pyd;
    address[] public strategies;
    mapping(address => uint256) public pendingFees;
    mapping(address => uint256) public claimed;
    uint256 public totalFees;
    
    constructor(address _pyd) Ownable(msg.sender) {
        pyd = IERC20(_pyd);
    }

    function addStrategy(address _strategy) external onlyOwner nonReentrant {
        strategies.push(_strategy);
    }

    function distribute() external onlyOwner nonReentrant {
        for (uint i = 0; i < strategies.length; i++) {
            _distributeStrategy(strategies[i]);
        }
    }

    function _distributeStrategy(address strategy) internal {
        uint256 fee = pendingFees[strategy];
        claimed[strategy] += fee;
        totalFees -= fee;
        pendingFees[strategy] = 0;
        pyd.transfer(strategy, fee);
    }

    function withdrawFees() external nonReentrant {
        uint256 amount = pendingFees[msg.sender];
        pendingFees[msg.sender] = 0;
        pyd.transfer(msg.sender, amount);
    }
}
