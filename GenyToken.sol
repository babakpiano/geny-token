// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/// @title GenyToken
/// @author compez.eth
/// @notice A minimal ERC20 token for the Genyleap ecosystem with a fixed supply of 256M, supporting voting and permit functionality.
/// @dev Implements core ERC20 functionality with permit for gasless approvals and votes for decentralized governance. All allocations and sensitive operations are handled by auxiliary contracts.
/// @custom:security-contact security@genyleap.com
contract GenyToken is ERC20, ERC20Permit, ERC20Votes {
    /// @dev Total token supply (256 million tokens with 18 decimals)
    uint256 internal constant _TOTAL_SUPPLY = 256_000_000 * 10 ** 18;

    /// @dev Token name and symbol
    string internal constant _TOKEN_NAME = "Genyleap";
    string internal constant _TOKEN_SYMBOL = "GENY";

    /// @notice Metadata URI (ERC-7572)
    string private immutable _contractURI;

    /// @notice Emitted once upon successful token deployment and allocation
    event Initialized(address indexed allocationContract, uint256 amount);

    /// @notice Token deployment and supply allocation
    /// @param allocationContract Recipient address of the initial supply
    /// @param contractURI_ Metadata URI for the token
    constructor(
        address allocationContract,
        string memory contractURI_
    ) payable ERC20(_TOKEN_NAME, _TOKEN_SYMBOL) ERC20Permit(_TOKEN_NAME) {
        require(msg.value == 0, "ETH not accepted");
        require(allocationContract != address(0), "Zero address not allowed");
        require(bytes(contractURI_).length != 0, "URI must be set");

        uint256 totalSupply = _TOTAL_SUPPLY; // Cache the total supply in memory
        string memory tokenName = _TOKEN_NAME; // Cache the token name in memory
        string memory tokenSymbol = _TOKEN_SYMBOL; // Cache the token symbol in memory

        _contractURI = contractURI_;
        _mint(allocationContract, totalSupply); // Use cached totalSupply

        emit Initialized(allocationContract, totalSupply); // Use cached totalSupply
    }

    /// @notice Contract metadata URI
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Returns fixed total supply
    function totalSupplyConstant() external pure returns (uint256) {
        return _TOTAL_SUPPLY;
    }

    /// @notice Returns token name
    function tokenName() external pure returns (string memory) {
        return _TOKEN_NAME;
    }

    /// @notice Returns token symbol
    function tokenSymbol() external pure returns (string memory) {
        return _TOKEN_SYMBOL;
    }

    /// @dev Hook for vote tracking
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    /// @dev Override for permit nonce handling
    function nonces(address owner)
        public
        view
        override(ERC20Permit)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @dev Override for EIP-712 domain separator
    function DOMAIN_SEPARATOR()
        public
        view
        override(ERC20Permit)
        returns (bytes32)
    {
        return super.DOMAIN_SEPARATOR();
    }
}
