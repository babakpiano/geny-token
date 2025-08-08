// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap
pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title GenyGuard (Emergency Recovery)
 * @author compez.eth
 * @notice Non-custodial, one-time-code recovery guard. Sensitive actions require a rotating recovery code.
 *         Only the keccak256 hash of the normalized code is stored on-chain.
 * @dev UUPS-upgradeable. Codes are 28 alphanumeric chars (A–Z, 0–9), case-insensitive; hyphens are allowed
 *      for UX but ignored during normalization.
 */
contract GenyGuard is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    // --- Storage ---
    mapping(address => address) private _recoveryWallet;
    mapping(address => bool)    private _recoveryModeActivated;
    mapping(address => bool)    private _isCompromised;
    mapping(address => bytes32) private _recoveryKeyHash;

    // --- Events ---
    event RecoveryWalletSet(address indexed user, address indexed recoveryWallet);
    event RecoveryModeActivated(address indexed user);
    event RecoveryModeDeactivated(address indexed user);
    event AddressCompromised(address indexed compromisedWallet);
    event RecoveryKeyRotated(address indexed user, bytes32 indexed newRecoveryKeyHash);

    // --- Errors ---
    error InvalidAddress();
    error InvalidCode();
    error InvalidCodeFormat();
    error RecoveryWalletAlreadySet();
    error RecoveryWalletNotSet();
    error RecoveryKeyAlreadySet();
    error RecoveryKeyNotSet();
    error RecoveryModeAlreadyActive();
    error NotInRecoveryMode();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize (UUPS).
     * @param owner_ Contract owner (multisig/timelock).
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert InvalidAddress();
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        _transferOwnership(owner_);
    }

    // ========= User flows =========

    /**
     * @notice Sets the initial recovery key hash (one-time).
     * @param recoveryKeyHash keccak256(normalized 28-char code).
     */
    function setRecoveryKey(bytes32 recoveryKeyHash) external {
        if (recoveryKeyHash == bytes32(0)) revert InvalidCode();
        if (_recoveryKeyHash[msg.sender] != bytes32(0)) revert RecoveryKeyAlreadySet();
        _recoveryKeyHash[msg.sender] = recoveryKeyHash;
        emit RecoveryKeyRotated(msg.sender, recoveryKeyHash);
    }

    /**
     * @notice Sets the recovery wallet (one-time). Requires current code and rotates to a new code.
     */
    function setRecoveryWallet(address wallet, string calldata code, bytes32 newRecoveryKeyHash) external {
        if (wallet == address(0)) revert InvalidAddress();
        if (_recoveryWallet[msg.sender] != address(0)) revert RecoveryWalletAlreadySet();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryWallet[msg.sender] = wallet;
        emit RecoveryWalletSet(msg.sender, wallet);
    }

    /**
     * @notice Activates recovery mode. Requires current code and rotates to a new code.
     */
    function activateRecoveryMode(string calldata code, bytes32 newRecoveryKeyHash) external {
        if (_recoveryWallet[msg.sender] == address(0)) revert RecoveryWalletNotSet();
        if (_recoveryModeActivated[msg.sender]) revert RecoveryModeAlreadyActive();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryModeActivated[msg.sender] = true;
        _isCompromised[msg.sender] = true; // intentionally persistent until explicit off-chain resolution
        emit RecoveryModeActivated(msg.sender);
        emit AddressCompromised(msg.sender);
    }

    /**
     * @notice Changes the recovery wallet. Requires current code and rotates to a new code.
     */
    function changeRecoveryWallet(address newWallet, string calldata code, bytes32 newRecoveryKeyHash) external {
        if (newWallet == address(0)) revert InvalidAddress();
        if (_recoveryWallet[msg.sender] == address(0)) revert RecoveryWalletNotSet();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryWallet[msg.sender] = newWallet;
        emit RecoveryWalletSet(msg.sender, newWallet);
    }

    /**
     * @notice Deactivates recovery mode. Requires current code and rotates to a new code.
     * @dev `_isCompromised` remains true by design (audit trail). If you want to clear it, add a separate admin/user flow.
     */
    function deactivateRecoveryMode(string calldata code, bytes32 newRecoveryKeyHash) external {
        if (!_recoveryModeActivated[msg.sender]) revert NotInRecoveryMode();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryModeActivated[msg.sender] = false;
        emit RecoveryModeDeactivated(msg.sender);
    }

    // ========= Internal logic =========

    /**
     * @dev Validates the current code and rotates to the next code hash.
     */
    function _rotateRecoveryKey(string calldata code, bytes32 newRecoveryKeyHash) internal {
        bytes32 current = _recoveryKeyHash[msg.sender];
        if (current == bytes32(0)) revert RecoveryKeyNotSet();
        if (!_isValidRecoveryCode(code)) revert InvalidCodeFormat();
        if (keccak256(abi.encodePacked(_normalizeCode(code))) != current) revert InvalidCode();
        if (newRecoveryKeyHash == bytes32(0) || newRecoveryKeyHash == current) revert InvalidCode();
        _recoveryKeyHash[msg.sender] = newRecoveryKeyHash;
        emit RecoveryKeyRotated(msg.sender, newRecoveryKeyHash);
    }

    /**
     * @dev Validates code charset/length: exactly 28 alphanumeric chars; hyphens are allowed and ignored.
     */
    function _isValidRecoveryCode(string calldata code) internal pure returns (bool ok) {
        bytes calldata b = bytes(code);
        uint256 len = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == bytes1(0x2D)) continue; // '-'
            // '0'..'9' (0x30..0x39), 'A'..'Z' (0x41..0x5A), 'a'..'z' (0x61..0x7A)
            bool isNum = (c >= 0x30 && c <= 0x39);
            bool isUp  = (c >= 0x41 && c <= 0x5A);
            bool isLo  = (c >= 0x61 && c <= 0x7A);
            if (!(isNum || isUp || isLo)) return false;
            unchecked { ++len; }
        }
        return len == 28;
    }

    /**
     * @dev Uppercases and strips hyphens. Returns a 28-byte string (no hyphens).
     */
    function _normalizeCode(string calldata code) internal pure returns (string memory out) {
        bytes calldata b = bytes(code);
        bytes memory nrm = new bytes(28);
        uint256 n = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == bytes1(0x2D)) continue; // '-'
            // to upper if 'a'..'z'
            if (c >= 0x61 && c <= 0x7A) {
                nrm[n++] = bytes1(uint8(c) - 32);
            } else {
                nrm[n++] = c;
            }
            if (n == 28) break;
        }
        return string(nrm);
    }

    // ========= Views =========

    function getRecoveryWallet(address user) external view returns (address) {
        return _recoveryWallet[user];
    }

    function isRecoveryModeActive(address user) external view returns (bool) {
        return _recoveryModeActivated[user];
    }

    function isCompromised(address user) external view returns (bool) {
        return _isCompromised[user];
    }

    function getRecoveryKeyHash(address user) external view returns (bytes32) {
        return _recoveryKeyHash[user];
    }

    // ========= Upgrades =========
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Storage gap for future variable additions (OZ pattern).
    /// If you add new state variables at the end in a future upgrade,
    /// decrease the length of this array by the same number of slots.
    uint256[50] private __gap;
}
