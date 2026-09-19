// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ProYieldVault is BaseStrategy {
    using SafeERC20 for IERC20;
    uint256 public performanceFee;
    uint256 public immutable withdrawalFee;
    uint256 public constant RESERVE_BPS = 1000; // 10% of assets kept liquid for withdrawals
    address public immutable feeDistributor;
    mapping(address => bool) public strategies;
    mapping(address => bool) public strategyActive;   // per-strategy circuit breaker
    uint256 private _totalAssets;
    address[] public strategyList;

    constructor(
        address _underlying,
        address initialOwner,
        address _feeDistributor
    ) BaseStrategy(_underlying, initialOwner, "ProYieldVault") {
        require(_feeDistributor != address(0), "ProYieldVault: zero feeDistributor");
        require(_underlying != address(0), "ProYieldVault: zero underlying");
        require(initialOwner != address(0), "ProYieldVault: zero owner");
        feeDistributor = _feeDistributor;
        performanceFee = 1000;
        withdrawalFee = 50;
    }

    function name() external view override returns (string memory) {
        return "ProYieldVault";
    }

    function totalAssets() public override view returns (uint256) {
        return _totalAssets;
    }

    function addStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "ProYieldVault: zero strategy");
        strategies[strategy] = true;
        strategyActive[strategy] = true;   // new strategies start active
        strategyList.push(strategy);
    }

    /// @notice Quarantine one strategy without stopping the whole vault.
    /// Inactive strategies are skipped by allocate() and cannot be harvested into.
    function setStrategyActive(address strategy, bool active) external onlyOwner {
        require(strategies[strategy], "ProYieldVault: not a strategy");
        strategyActive[strategy] = active;
    }

    function deposit(uint256 amount) external override nonReentrant {
        require(amount > 0, "ProYieldVault: zero amount");
        shares[msg.sender] += amount;
        _totalAssets += amount;
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    function setPerformanceFee(uint256 fee) external onlyOwner {
        require(fee <= 10000, "ProYieldVault: fee too high");
        performanceFee = fee;
    }

    function emergencyWithdraw() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        if (balance == 0) return;
        underlying.safeTransfer(msg.sender, balance);
        // Keep liabilities in sync: assets leaving the vault must shrink
        // totalAssets or depositor claims exceed real backing (T-012 follow-up).
        _totalAssets -= balance;
    }

    function allocate() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        // Keep a liquid reserve so withdrawals never depend on strategy recall.
        uint256 reserve = (_totalAssets * RESERVE_BPS) / 10000;
        uint256 deployable = balance > reserve ? balance - reserve : 0;
        if (deployable > 0 && strategyList.length > 0) {
            // Split only across ACTIVE strategies; inactive ones get nothing.
            uint256 activeCount = 0;
            for (uint i = 0; i < strategyList.length; i++) {
                if (strategies[strategyList[i]] && strategyActive[strategyList[i]]) {
                    activeCount++;
                }
            }
            if (activeCount == 0) return;
            uint256 perStrategy = deployable / activeCount;
            for (uint i = 0; i < strategyList.length; i++) {
                address strategy = strategyList[i];
                if (strategies[strategy] && strategyActive[strategy] && perStrategy > 0) {
                    underlying.safeTransfer(strategy, perStrategy);
                }
            }
        }
    }

    /// @notice Pull funds back from strategies until `needed` is idle.
    /// Splits the shortfall across active strategies; recall is capped at each
    /// strategy's balance, so a shortfall larger than total recalled reverts
    /// downstream (correct behavior — cannot pay out assets that don't exist).
    function _recallShortfall(uint256 needed) internal {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle >= needed) return;
        uint256 missing = needed - idle;
        uint256 activeCount = 0;
        for (uint i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]] && strategyActive[strategyList[i]]) {
                activeCount++;
            }
        }
        if (activeCount == 0) return; // withdraw will revert on insufficient idle
        uint256 perStrategy = (missing / activeCount) + 1; // round up
        for (uint i = 0; i < strategyList.length && missing > 0; i++) {
            address strategy = strategyList[i];
            if (strategies[strategy] && strategyActive[strategy]) {
                BaseStrategy(strategy).recall(perStrategy);
                uint256 got = underlying.balanceOf(address(this)) - idle;
                idle += got;
                missing = got >= missing ? 0 : missing - got;
            }
        }
    }

    /// @notice User withdrawal. Shares are 1:1 with deposited USDC.
    /// Pays from idle; recalls from strategies to cover any shortfall.
    /// Overrides BaseStrategy.withdraw, whose proportional share math
    /// under-burned shares on partial withdrawals (drain vector) and which
    /// could not honor withdrawals once allocate() had swept idle funds (T-012).
    function withdraw(uint256 amount) external override nonReentrant {
        require(amount > 0, "ProYieldVault: zero amount");
        require(amount <= shares[msg.sender], "ProYieldVault: exceeds shares");
        require(amount <= totalAssets(), "ProYieldVault: exceeds assets");
        // Effects BEFORE interactions (slither reentrancy-no-eth): burn shares
        // and shrink liabilities before any external recall call.
        shares[msg.sender] -= amount;
        _totalAssets -= amount;
        _recallShortfall(amount);
        underlying.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function harvest() external override nonReentrant {
        lastHarvest = block.timestamp;
        emit Harvest(0);
    }

    function harvestStrategy(address strategy) external onlyOwner nonReentrant {
        require(strategies[strategy], "ProYieldVault: not a strategy");
        require(strategyActive[strategy], "ProYieldVault: strategy paused");
        require(strategy != address(0), "ProYieldVault: zero strategy");
        BaseStrategy(strategy).harvest();
    }
}
