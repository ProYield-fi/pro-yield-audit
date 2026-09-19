// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ProYieldVault is BaseStrategy {
    using SafeERC20 for IERC20;
    uint256 public performanceFee;
    uint256 public withdrawalFee;
    address public feeDistributor;
    mapping(address => bool) public strategies;
    uint256 private _totalAssets;
    address[] public strategyList;

    constructor(
        address _underlying,
        address _owner,
        address _feeDistributor
    ) BaseStrategy(_underlying, _owner, "ProYieldVault") {
        feeDistributor = _feeDistributor;
        performanceFee = 1000; // 10%
        withdrawalFee = 50; // 0.5%
    }

    function name() external view override returns (string memory) {
        return "ProYieldVault";
    }

    function totalAssets() public override view returns (uint256) {
        return _totalAssets;
    }

    function addStrategy(address _strategy) external onlyOwner {
        strategies[_strategy] = true;
        strategyList.push(_strategy);
    }

    function deposit(uint256 amount) external override nonReentrant {
        shares[msg.sender] += amount;
        _totalAssets += amount;
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    function setPerformanceFee(uint256 _fee) external onlyOwner {
        performanceFee = _fee;
    }

    function emergencyWithdraw() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        underlying.safeTransfer(msg.sender, balance);
    }

    function allocate() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        if (balance > 0 && strategyList.length > 0) {
            uint256 perStrategy = balance / strategyList.length;
            for (uint i = 0; i < strategyList.length; i++) {
                address strategy = strategyList[i];
                if (strategies[strategy] && perStrategy > 0) {
                    underlying.safeTransfer(strategy, perStrategy);
                }
            }
        }
    }

    function harvest() external override nonReentrant {
        uint256 totalProfit = 0;
        for (uint i = 0; i < strategyList.length; i++) {
            address strategy = strategyList[i];
            if (strategies[strategy]) {
                BaseStrategy(strategy).harvest();
            }
        }
        lastHarvest = block.timestamp;
        emit Harvest(totalProfit);
    }
}
