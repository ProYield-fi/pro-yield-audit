// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BaseStrategy is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    address public keeper;
    address public vault; // authorized to recall funds for user withdrawals
    // slither-disable-next-line constable-states
    uint256 public totalDebt;
    bool public isActive;
    // slither-disable-next-line immutable-states
    uint256 public lastHarvest;
    mapping(address => uint256) public shares;
    string public name_;

    // MAX_WITHDRAWAL_FEE / MAX_PERFORMANCE_FEE lived here as unused public
    // getters; removed for the HyperEVM 3,000,000-gas deploy budget (the
    // vault owns fee policy — its own constants).

    event Harvest(uint256 profit);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event KeeperSet(address indexed keeper);
    event ActiveChanged(bool active);

    constructor(address _underlying, address initialOwner, string memory _name) Ownable(initialOwner) {
        require(_underlying != address(0), "BaseStrategy: zero underlying");
        require(initialOwner != address(0), "BaseStrategy: zero owner");
        underlying = IERC20(_underlying);
        isActive = true;
        name_ = _name;
        lastHarvest = block.timestamp;
    }

    function name() external view virtual returns (string memory) {
        return name_;
    }

    /// @dev The vault OVERRIDES this (its deposit is the user-facing one).
    /// Kept on the base so ProYieldVault's `override` stays valid; strategy
    /// instances never receive deposits through it (the vault allocate()
    /// path is a plain safeTransfer).
    function deposit(uint256 amount) external virtual nonReentrant {
        require(amount > 0, "BaseStrategy: zero amount");
        shares[msg.sender] += amount;
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    // NOTE: user-facing withdraw lives ONLY in ProYieldVault (1:1 shares +
    // strategy recall). The former BaseStrategy.withdraw here used broken
    // proportional share math (under-burned shares on partial withdrawals —
    // drain vector) and was removed so it can never be inherited again (T-012).

    function harvest() external virtual nonReentrant {
        require(isActive, "BaseStrategy: inactive");
        uint256 profit = _doHarvest();
        totalDebt += profit;
        lastHarvest = block.timestamp;
        emit Harvest(profit);
    }

    // slither-disable-next-line dead-code
    function _doHarvest() internal virtual returns (uint256) {
        return 0;
    }

    function setKeeper(address keeper_) external onlyOwner nonReentrant {
        require(keeper_ != address(0), "BaseStrategy: zero keeper");
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setVault(address vault_) external onlyOwner nonReentrant {
        require(vault_ != address(0), "BaseStrategy: zero vault");
        vault = vault_;
    }

    /// @notice Return funds to the vault so it can honor user withdrawals.
    /// Callable ONLY by the vault address (set via setVault). Capped at balance.
    function recall(uint256 amount) external nonReentrant {
        require(msg.sender == vault, "BaseStrategy: not vault");
        uint256 bal = underlying.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        underlying.safeTransfer(vault, amount);
    }

    function setActive(bool active) external onlyOwner nonReentrant {
        isActive = active;
        emit ActiveChanged(active);
    }

    function totalAssets() public virtual view returns (uint256) {
        return underlying.balanceOf(address(this));
    }
}
