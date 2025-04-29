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
    /// @dev Total token supply (256 million tokens with 18 decimals) — defined as internal constant to avoid auto-generated getter
    uint256 internal constant _TOTAL_SUPPLY = 256_000_000 * 10 ** 18;

    /// @dev Token name and symbol — internal to avoid getter gas cost
    string internal constant _TOKEN_NAME = "Genyleap";
    string internal constant _TOKEN_SYMBOL = "GENY";

    /// @notice Contract URI for token metadata (ERC-7572)
    string private immutable _contractURI;

    /// @notice Event emitted when the contract is initialized and the total supply is minted
    event Initialized(address indexed allocationContract, uint256 amount);

    /// @notice Constructor to deploy the token and mint the total supply to the allocation contract
    /// @param allocationContract Address to receive the total supply
    /// @param contractURI_ Contract URI to set for the token
    constructor(
        address allocationContract,
        string memory contractURI_
    ) ERC20(_TOKEN_NAME, _TOKEN_SYMBOL) ERC20Permit(_TOKEN_NAME) {
        require(allocationContract != address(0), "Allocation contract cannot be address zero");
        require(bytes(contractURI_).length != 0, "URI needs to be set");

        _contractURI = contractURI_;
        _mint(allocationContract, _TOTAL_SUPPLY);

        emit Initialized(allocationContract, _TOTAL_SUPPLY);
    }

    /// @notice Returns the contract URI for token metadata
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Returns the total supply constant
    function totalSupplyConstant() external pure returns (uint256) {
        return _TOTAL_SUPPLY;
    }

    /// @notice Returns the token name
    function tokenName() external pure returns (string memory) {
        return _TOKEN_NAME;
    }

    /// @notice Returns the token symbol
    function tokenSymbol() external pure returns (string memory) {
        return _TOKEN_SYMBOL;
    }

    /// @dev Overrides for ERC20 and ERC20Votes inheritance
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._update(from, to, amount);
    }

    /// @dev Overrides for ERC20Permit inheritance
    function nonces(address owner) public view virtual override(ERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }
}
