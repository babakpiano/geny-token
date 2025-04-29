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
    /// @notice Total token supply (256 million tokens with 18 decimals)
    uint256 public constant TOTAL_SUPPLY = 256_000_000 * 10 ** 18;

    /// @notice Token name
    string public constant TOKEN_NAME = "Genyleap";

    /// @notice Token symbol
    string public constant TOKEN_SYMBOL = "GENY";

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
    ) ERC20("Genyleap", "GENY") ERC20Permit("Genyleap") {
        require(allocationContract != address(0), "Allocation contract cannot be address zero");
        require(bytes(contractURI_).length > 0, "URI needs to be set");

        _contractURI = contractURI_;
        _mint(allocationContract, TOTAL_SUPPLY);

        emit Initialized(allocationContract, TOTAL_SUPPLY);
    }

    /// @notice Returns the contract URI for token metadata
    /// @return Contract URI set for the token
    function contractURI() external view returns (string memory) {
        return _contractURI;
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