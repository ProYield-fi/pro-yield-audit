// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PYDStaking is Ownable, ReentrancyGuard {
    IERC20 public pyd;
    mapping(address => uint256) public stakeAmount;
    uint256 public totalSupply;
    uint256 public constant REWARD_RATE = 100;
    
    constructor(address _pyd) Ownable(msg.sender) {
        pyd = IERC20(_pyd);
    }

    function stake(uint256 amount) external nonReentrant {
        stakeAmount[msg.sender] += amount;
        totalSupply += amount;
        pyd.transferFrom(msg.sender, address(this), amount);
    }

    function getReward() external nonReentrant {
        uint256 reward = _calculateReward(msg.sender);
        pyd.transfer(msg.sender, reward);
    }

    function _calculateReward(address user) internal view returns (uint256) {
        return stakeAmount[user] * REWARD_RATE;
    }
}
