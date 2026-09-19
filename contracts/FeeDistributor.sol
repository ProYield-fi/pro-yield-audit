// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FeeDistributor is ReentrancyGuard {
    IERC20 public pyd;
    address[] public strategies;
    mapping(address => uint256) public pendingFees;
    mapping(address => uint256) public claimed;
    uint256 public totalFees;
    address public owner;
    
    constructor(address _pyd) {
        pyd = IERC20(_pyd);
        owner = msg.sender;
    }

    function addStrategy(address _strategy) external onlyOwner nonReentrant {
        strategies.push(_strategy);
    }

    function distribute() external onlyOwner nonReentrant {
        for (uint i = 0; i < strategies.length; i++) {
            uint256 fee = pendingFees[strategies[i]];
            pendingFees[strategies[i]] = 0;
            claimed[strategies[i]] += fee;
            totalFees -= fee;
            pyd.transfer(strategies[i], fee);
        }
    }

    function withdrawFees() external nonReentrant {
        uint256 amount = pendingFees[msg.sender];
        pendingFees[msg.sender] = 0;
        pyd.transfer(msg.sender, amount);
    }
}
