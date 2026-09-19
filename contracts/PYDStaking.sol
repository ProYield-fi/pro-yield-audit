// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PYDStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public pyd;
    mapping(address => uint256) public stakeAmount;
    mapping(address => uint256) public rewardDebt;
    uint256 public totalSupply;
    uint256 public constant REWARD_RATE = 100;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    constructor(address _pyd) Ownable(msg.sender) {
        pyd = IERC20(_pyd);
    }

    function name() external view returns (string memory) {
        return "PYDStaking";
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "PYDStaking: amount is 0");
        pyd.safeTransferFrom(msg.sender, address(this), amount);
        _updateReward(msg.sender);
        stakeAmount[msg.sender] += amount;
        totalSupply += amount;
        emit Stake(msg.sender, amount);
    }

    function getReward() external nonReentrant {
        _updateReward(msg.sender);
        uint256 reward = _calculateReward(msg.sender);
        require(reward > 0, "PYDStaking: no reward");
        pyd.safeTransfer(msg.sender, reward);
        rewardDebt[msg.sender] = _rewardPerToken();
        emit Reward(msg.sender, reward);
    }

    function _calculateReward(address user) internal view returns (uint256) {
        return stakeAmount[user] * REWARD_RATE;
    }

    function _rewardPerToken() internal view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((_earnedPerBlock() * 1e18) / totalSupply);
    }

    function _earnedPerBlock() internal view returns (uint256) {
        return REWARD_RATE;
    }

    function _updateReward(address user) internal {
        rewardDebt[user] = _rewardPerToken();
    }

    event Stake(address indexed user, uint256 amount);
    event Reward(address indexed user, uint256 amount);
}
