// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BaseStrategy is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public underlying;
    address public keeper;
    uint256 public totalDebt;
    bool public isActive;
    uint256 public lastHarvest;
    mapping(address => uint256) public shares;
    string public name_;

    event Harvest(uint256 profit);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    constructor(address _underlying, address _owner, string memory _name) Ownable(_owner) {
        underlying = IERC20(_underlying);
        isActive = true;
        name_ = _name;
    }

    function name() external view virtual returns (string memory) {
        return name_;
    }

    function deposit(uint256 amount) external virtual nonReentrant {
        shares[msg.sender] += amount;
        uint256 balance = underlying.balanceOf(address(this));
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        uint256 newBalance = underlying.balanceOf(address(this)) - balance;
        if (newBalance > 0) {
            shares[msg.sender] += (newBalance * shares[msg.sender]) / balance;
        }
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external virtual nonReentrant {
        uint256 totalShares = _totalShares();
        require(totalShares > 0, "BaseStrategy: no shares");
        uint256 shareAmount = (amount * shares[msg.sender]) / totalAssets();
        require(shareAmount > 0, "BaseStrategy: insufficient shares");
        shares[msg.sender] -= shareAmount;
        underlying.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function harvest() external virtual nonReentrant {
        uint256 profit = _doHarvest();
        emit Harvest(profit);
        lastHarvest = block.timestamp;
    }

    function _doHarvest() internal virtual returns (uint256) {
        return 0;
    }

    function setKeeper(address _keeper) external onlyOwner nonReentrant {
        keeper = _keeper;
    }

    function totalAssets() public virtual view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function _totalShares() internal view returns (uint256) {
        // Sum all shares
        uint256 total = 0;
        // This is a simplified version — in production, track totalSupply separately
        return total;
    }
}
