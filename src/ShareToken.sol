// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ShareToken
 * @notice Non-transferable ERC20 representing pool ownership shares
 * @dev Only the Pool contract can mint/burn. Transfers are disabled.
 */
contract ShareToken is ERC20 {
    address public immutable pool;

    error OnlyPool();
    error TransfersDisabled();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        pool = msg.sender;
    }

    /**
     * @notice Mint shares to a member (only callable by Pool)
     * @param to Address to mint to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    /**
     * @notice Burn shares from a member (only callable by Pool)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }

    /**
     * @dev Override to disable transfers (soulbound)
     */
    function transfer(address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    /**
     * @dev Override to disable transfers (soulbound)
     */
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    /**
     * @dev Override to disable approvals (not needed since transfers disabled)
     */
    function approve(address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }
}
