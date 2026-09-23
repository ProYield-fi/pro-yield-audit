// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice PYD staking with time-based reward accrual (Synthetix-style).
/// FIX (audit 09-20): the previous getReward() paid stakeAmount x REWARD_RATE
/// — 100x the staker's own deposit, from a contract holding only 1x — an
/// instant revert DoS. Rewards now accrue per-second, pro-rata by stake, from
/// an explicitly funded reward pool; users can never claim more than exists.
contract PYDStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable pyd;

    mapping(address => uint256) public stakeAmount;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    uint256 public totalSupply;

    uint256 public rewardRate;          // PYD per second across all stakers
    uint256 public rewardsDuration;     // seconds the current rate runs
    uint256 public periodFinish;        // timestamp current rate ends
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    event Stake(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Reward(address indexed user, uint256 amount);
    event RewardsFunded(uint256 amount, uint256 duration);

    constructor(address _pyd) Ownable(msg.sender) {
        require(_pyd != address(0), "PYDStaking: zero pyd");
        pyd = IERC20(_pyd);
        lastUpdateTime = block.timestamp;
    }

    function name() external pure returns (string memory) {
        return "PYDStaking";
    }

    // ── Operator: fund the reward pool ──────────────────────────────
    function fundRewards(uint256 amount, uint256 duration) external onlyOwner nonReentrant {
        require(amount > 0 && duration > 0, "PYDStaking: zero");
        // Bank every reward accrued so far at the OLD rate BEFORE any window
        // mutation. Without this, resetting lastUpdateTime below silently
        // ERASES all accrual since the last user interaction (found by the
        // mid-period top-up test: 33k PYD vanished).
        //
        // ORDER MATTERS: _updatePeriod() FIRST — it banks the expired window's
        // final stretch exactly once (and zeroes the old rate); the following
        // _rewardPerToken() is then a no-op in that case, and only banks
        // accrual-to-now for mid-period top-ups. The reversed order
        // double-counted the whole tail of an expired window whenever
        // fundRewards ran after a lapse with NO user interaction in between —
        // rewards became claimable beyond the funded pool, eating staked
        // principal (caught by the foundry invariant suite: fundRewards after
        // lapse → balance < totalSupply).
        _updatePeriod();
        rewardPerTokenStored = _rewardPerToken();
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / duration;
        } else {
            // mid-period top-up: unspent remainder rolls into the new window
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (amount + leftover) / duration;
        }
        rewardsDuration = duration;
        periodFinish = block.timestamp + duration;
        lastUpdateTime = block.timestamp;
        pyd.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(amount, duration);
    }

    // ── Staker actions ──────────────────────────────────────────────
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "PYDStaking: amount is 0");
        _updatePeriod();
        _updateReward(msg.sender);
        pyd.safeTransferFrom(msg.sender, address(this), amount);
        stakeAmount[msg.sender] += amount;
        totalSupply += amount;
        emit Stake(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "PYDStaking: amount is 0");
        _updatePeriod();
        _updateReward(msg.sender);
        require(stakeAmount[msg.sender] >= amount, "PYDStaking: insufficient stake");
        stakeAmount[msg.sender] -= amount;
        totalSupply -= amount;
        pyd.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function getReward() external nonReentrant {
        _updatePeriod();
        _updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            // pool always holds staked + funded rewards; never over-pays
            rewards[msg.sender] = 0;
            pyd.safeTransfer(msg.sender, reward);
            emit Reward(msg.sender, reward);
        }
    }

    /// Compound exit: principal + rewards in one tx. Inlined (NOT this.withdraw/
    /// this.getReward — external self-call makes msg.sender the contract itself,
    /// breaking every msg.sender-keyed lookup).
    function exit() external nonReentrant {
        _updatePeriod();
        _updateReward(msg.sender);
        uint256 amt = stakeAmount[msg.sender];
        if (amt > 0) {
            stakeAmount[msg.sender] = 0;
            totalSupply -= amt;
            pyd.safeTransfer(msg.sender, amt);
            emit Withdraw(msg.sender, amt);
        }
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            pyd.safeTransfer(msg.sender, reward);
            emit Reward(msg.sender, reward);
        }
    }

    // ── Views ───────────────────────────────────────────────────────
    function earned(address account) external view returns (uint256) {
        return rewards[account] + (stakeAmount[account] * (_rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18;
    }

    // ── Internals ───────────────────────────────────────────────────
    function _rewardPerToken() internal view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        uint256 lastApplicable = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (lastApplicable <= lastUpdateTime) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastApplicable - lastUpdateTime) * rewardRate * 1e18) / totalSupply;
    }

    function _updatePeriod() internal {
        if (block.timestamp >= periodFinish && periodFinish > 0) {
            // Bank the FINAL stretch (lastUpdateTime -> periodFinish) BEFORE
            // zeroing the rate. Zeroing first erased the unbanked tail for any
            // claim made after periodFinish (found by the staggered-join test:
            // a 4-day window — 40k PYD — silently lost). Idempotent: a second
            // call with lastUpdateTime == periodFinish returns stored.
            rewardPerTokenStored = _rewardPerToken();
            lastUpdateTime = periodFinish;
            rewardRate = 0; // no further accrual past the funded window
        }
    }

    function _updateReward(address account) internal {
        rewardPerTokenStored = _rewardPerToken();
        lastUpdateTime = lastT();
        rewards[account] += (stakeAmount[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / 1e18;
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }

    function lastT() internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }
}
