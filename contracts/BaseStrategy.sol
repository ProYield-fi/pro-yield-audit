// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BaseStrategy is Ownable, ReentrancyGuard {
    IERC20 public underlying;
    address public keeper;
    uint256 public totalDebt;
    bool public isActive;
    uint256 public lastHarvest;
    mapping(address => uint256) public shares;

    event Harvest(uint256 profit);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    constructor(address _underlying, address _owner) Ownable(_owner) {
        underlying = IERC20(_underlying);
        isActive = true;
    }

    function deposit(uint256 amount) external virtual {
        underlying.transferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external virtual {
        uint256 shareAmount = amount;
        shares[msg.sender] -= shareAmount;
        underlying.transfer(msg.sender, shareAmount);
        emit Withdraw(msg.sender, amount);
    }

    function harvest() external virtual {}

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }
}
