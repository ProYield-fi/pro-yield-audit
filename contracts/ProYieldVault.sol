// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ProYieldVault is BaseStrategy {
    using SafeERC20 for IERC20;
    uint256 public performanceFee;
    uint256 public immutable withdrawalFee;
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
        underlying.safeTransfer(msg.sender, balance);
    }

    function allocate() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        uint256 len = strategyList.length;   // cache length (slither: cache-array-length)
        if (balance > 0 && len > 0) {
            // Split only across ACTIVE strategies; inactive ones get nothing.
            uint256 activeCount = 0;
            for (uint i = 0; i < len; i++) {
                address s = strategyList[i];
                if (strategies[s] && strategyActive[s]) {
                    activeCount++;
                }
            }
            if (activeCount == 0) return;
            uint256 perStrategy = balance / activeCount;
            for (uint i = 0; i < len; i++) {
                address s = strategyList[i];
                if (strategies[s] && strategyActive[s] && perStrategy > 0) {
                    underlying.safeTransfer(s, perStrategy);
                }
            }
        }
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
