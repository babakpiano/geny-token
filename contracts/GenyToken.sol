// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IGenyGuard} from "./interfaces/IGenyGuard.sol";

/// @title GenyToken
/// @author compez.eth
/// @notice An ERC20 token with a fixed supply of 256 million, designed to empower creators and drive innovation in the Genyleap ecosystem.
/// @dev Extends OpenZeppelin's ERC20 with burnable, permit, votes, pausability, Ownable2Step (inherits Ownable), and optional GenyGuard integration.
/// @custom:security-contact security@genyleap.com
contract GenyToken is
    ERC20,
    ERC20Burnable,
    ERC20Permit,
    ERC20Votes,
    ERC20Pausable,
    Ownable2Step
{
    /// @dev Fixed total token supply (256 million tokens with 18 decimals)
    uint256 internal constant _TOTAL_SUPPLY = 2.56e8 * 1e18; // 256,000,000

    /// @dev Cached token name/symbol (optional; could rely on ERC20 defaults)
    string private _tokenNameStr;
    string private _tokenSymbolStr;

    /// @dev ERC-7572 contract-level metadata URI
    string private _contractURI;

    /// @notice GenyGuard contract for recovery enforcement (optional; zero disables)
    address public immutable genyGuard;

    /// @notice Emitted once upon successful token deployment and initial allocation
    event Initialized(address indexed allocationContract, uint256 amount);
    /// @notice Emitted when token name and symbol are set during deployment
    event TokenMetadataSet(string indexed name, string indexed symbol);
    /// @notice Emitted when the contract metadata URI is set during deployment
    event ContractURISet(string indexed uri);
    /// @notice Pause/unpause audit trail
    event PausedBy(address indexed owner);
    event UnpausedBy(address indexed owner);
    /// @notice Snapshot marker using EIP-6372 clock (timestamp-based)
    event SnapshotTaken(uint48 indexed clockValue);

    // errors
    error ZeroAddressNotAllowed();
    error URIMustBeSet();
    error CannotReceiveEther();
    error OnlyToRecovery();
    error InvalidRecoveryWallet();
    error InvalidGenyGuardAddress(); // non-zero but not a contract

    /// @notice Prevent accidental ETH
    receive() external payable { revert CannotReceiveEther(); }
    fallback() external payable { revert CannotReceiveEther(); }

    /// @param allocationContract Receiver of initial supply & initial owner
    /// @param contractURI_ ERC-7572 contract URI
    /// @param genyGuard_ GenyGuard address (zero disables recovery enforcement)
    constructor(
        address allocationContract,
        string memory contractURI_,
        address genyGuard_
    )
        ERC20("Genyleap", "GENY")
        ERC20Permit("Genyleap")
        Ownable(allocationContract)
    {
        if (allocationContract == address(0)) revert ZeroAddressNotAllowed();
        if (bytes(contractURI_).length == 0) revert URIMustBeSet();

        // Allow null guard. If provided, must be a contract to avoid ABI decode reverts.
        if (genyGuard_ != address(0)) {
            if (genyGuard_.code.length == 0) revert InvalidGenyGuardAddress();
        }
        genyGuard = genyGuard_;

        _tokenNameStr = "Genyleap";
        _tokenSymbolStr = "GENY";
        emit TokenMetadataSet(_tokenNameStr, _tokenSymbolStr);

        _contractURI = contractURI_;
        emit ContractURISet(_contractURI);

        uint256 totalSupply = _TOTAL_SUPPLY;
        _mint(allocationContract, totalSupply);
        emit Initialized(allocationContract, totalSupply);
    }

    /// @notice ERC-7572 metadata URI
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Fixed total supply (informational)
    function totalSupplyConstant() external pure returns (uint256) {
        return _TOTAL_SUPPLY;
    }

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        return _tokenNameStr;
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        return _tokenSymbolStr;
    }

    /// @dev Transfer/update hook with votes/pause + optional recovery enforcement
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes, ERC20Pausable)
    {
        if (genyGuard != address(0) && from != address(0) && from != to) {
            if (IGenyGuard(genyGuard).isRecoveryModeActive(from)) {
                address rw = IGenyGuard(genyGuard).getRecoveryWallet(from);
                if (rw == address(0) || rw == from) revert InvalidRecoveryWallet();
                if (to != rw) revert OnlyToRecovery();
            }
        }

        super._update(from, to, amount);
        // No extra event; rely on ERC20 Transfer + ERC20Votes events
    }

    /// @notice Pauses all token transfers and burns
    function pause() external onlyOwner {
        _pause();
        emit PausedBy(msg.sender);
    }

    /// @notice Unpauses all token transfers and burns
    function unpause() external onlyOwner {
        _unpause();
        emit UnpausedBy(msg.sender);
    }

    /// @notice Multiple inheritance fix for shared nonces (permit/votes)
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @notice Off-chain–friendly snapshot marker using EIP-6372 clock
    function snapshot() external onlyOwner {
        emit SnapshotTaken(clock());
    }

    /// @notice Convenience self-delegation helper
    function delegateToSelf() external {
        delegate(msg.sender);
        // NOTE: ERC20Votes emits DelegateChanged / DelegateVotesChanged
    }

    /// @dev EIP-6372 timestamp clock (OZ Governor >= 4.9 compatible)
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev EIP-6372 clock mode descriptor
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}