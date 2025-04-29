// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title GenyToken
/// @author compez.eth
/// @notice An ERC20 token with a fixed supply of 256 million, designed to empower creators and drive innovation in the Genyleap ecosystem.
/// @dev Extends OpenZeppelin's ERC20 with permit for gasless approvals and votes for decentralized governance. All allocations are handled by an external contract. Emits standard ERC20 events (Transfer, Approval) and ERC20Votes events (DelegateChanged, DelegateVotesChanged) for key operations; additional events are not defined due to the fixed supply and external allocation.
/// @custom:security-contact security@genyleap.com
contract GenyToken is ERC20, ERC20Permit, ERC20Votes {
    /// @dev Fixed total token supply (256 million tokens with 18 decimals)
    uint256 internal constant _TOTAL_SUPPLY = 2.56e8 * 1e18;

    /// @dev Token name stored as bytes32 for gas-efficient storage
    bytes32 internal constant _TOKEN_NAME = bytes32("Genyleap");

    /// @dev Token symbol stored as bytes32 for gas-efficient storage
    bytes32 internal constant _TOKEN_SYMBOL = bytes32("GENY");

    /// @dev Cached token name as string for ERC20 compatibility and gas optimization
    string private _tokenNameStr;

    /// @dev Cached token symbol as string for ERC20 compatibility and gas optimization
    string private _tokenSymbolStr;

    /// @dev Metadata URI for the token, compliant with ERC-7572
    string private _contractURI;

    /// @notice Emitted once upon successful token deployment and initial allocation
    /// @param allocationContract Address receiving the initial token supply
    /// @param amount Total number of tokens minted
    event Initialized(address indexed allocationContract, uint256 amount);

    /// @notice Deploys the token and allocates the total supply to the specified contract
    /// @dev Initializes token metadata and mints the fixed supply to the allocation contract
    /// @param allocationContract Address to receive the initial token supply
    /// @param contractURI_ Metadata URI for the token (ERC-7572)
    constructor(
        address allocationContract,
        string memory contractURI_
    ) payable ERC20(_tokenNameStr, _tokenSymbolStr) ERC20Permit(_tokenNameStr) {
        // Prevent ETH deposits during deployment
        require(msg.value == 0, "ETH not accepted");
        // Ensure allocation contract is not the zero address
        require(allocationContract != address(0), "Zero address not allowed");
        // Ensure metadata URI is not empty
        require(bytes(contractURI_).length != 0, "URI must be set");

        // Cache total supply in memory to reduce gas costs
        uint256 totalSupply = _TOTAL_SUPPLY;
        // Cache token name and symbol as strings for ERC20 compatibility
        _tokenNameStr = _bytes32ToString(_TOKEN_NAME);
        _tokenSymbolStr = _bytes32ToString(_TOKEN_SYMBOL);

        // Set metadata URI
        _contractURI = contractURI_;
        // Mint the fixed supply to the allocation contract
        _mint(allocationContract, totalSupply);

        // Emit initialization event
        emit Initialized(allocationContract, totalSupply);
    }

    /// @notice Returns the contract metadata URI (ERC-7572)
    /// @return The metadata URI as a string
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Returns the fixed total supply of the token
    /// @return The total supply in wei (256 million tokens with 18 decimals)
    function totalSupplyConstant() external pure returns (uint256) {
        return _TOTAL_SUPPLY;
    }

    /// @notice Returns the token name
    /// @return The token name as a string ("Genyleap")
    function tokenName() external view returns (string memory) {
        return _tokenNameStr;
    }

    /// @notice Returns the token symbol
    /// @return The token symbol as a string ("GENY")
    function tokenSymbol() external view returns (string memory) {
        return _tokenSymbolStr;
    }

    /// @dev Converts a bytes32 value to a string for ERC20 compatibility
    /// @param _bytes The bytes32 value to convert
    /// @return The converted string
    function _bytes32ToString(bytes32 _bytes) internal pure returns (string memory) {
        uint256 i = 0;
        // Iterate until end of bytes32 or null byte is found
        while (i < 32 && _bytes[i] != 0) {
            // Use unchecked block to skip overflow checks for gas optimization
            unchecked { ++i; }
        }
        // Create a byte array of the appropriate length
        bytes memory bytesArray = new bytes(i);
        // Copy bytes to the array
        for (uint256 j = 0; j < i; ++j) {
            bytesArray[j] = _bytes[j];
        }
        // Convert byte array to string
        return string(bytesArray);
    }

    /// @dev Updates token state for transfers, including vote tracking
    /// @param from Address sending the tokens
    /// @param to Address receiving the tokens
    /// @param amount Number of tokens transferred
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    /// @notice No-op inheritance fix to enable permit and votes functionality with shared nonce behavior
    /// @dev Overrides OpenZeppelin function to resolve ERC20Permit and Nonces inheritance conflict
    /// @param owner Address to retrieve the nonce for
    /// @return The current nonce for the specified owner
    function nonces(address owner)
        public
        view
        virtual
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}