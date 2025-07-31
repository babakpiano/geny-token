// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

/**
 * @title GenyGuard
 * @author compez.eth
 * @notice Modular, non-custodial, one-time code recovery protection for any EVM address. All sensitive actions require single-use, rotating recovery codes. No plaintext code is ever stored on-chain.
 * @dev Recovery codes are always 28-character alphanumeric (A-Z, 0-9), case-insensitive. Each sensitive operation requires the current code and a new code for rotation (hash of new code). This guarantees replay protection and robust off-chain security. Only the code hash is stored.
 * @custom:security-contact security@genyleap.com
 */
contract GenyGuard {
    /// @dev Maps each user to their registered recovery wallet
    mapping(address => address) private _recoveryWallet;
    /// @dev Indicates if recovery mode is currently active
    mapping(address => bool) private _recoveryModeActivated;
    /// @dev True if user has marked their account as compromised
    mapping(address => bool) private _isCompromised;
    /// @dev Stores the latest recovery code hash (rotated after every operation)
    mapping(address => bytes32) private _recoveryKeyHash;

    // --- Events ---
    event RecoveryWalletSet(address indexed user, address indexed recoveryWallet);
    event RecoveryModeActivated(address indexed user);
    event RecoveryModeDeactivated(address indexed user);
    event AddressCompromised(address indexed compromisedWallet);
    event RecoveryKeyRotated(address indexed user, bytes32 indexed newRecoveryKeyHash);

    // --- Errors ---
    error InvalidCode();
    error InvalidCodeFormat();
    error RecoveryWalletAlreadySet();
    error RecoveryKeyAlreadySet();
    error RecoveryKeyNotSet();
    error Unauthorized();
    error NotInRecoveryMode();

    // ====== USER FLOW ======

    /**
     * @notice Setup the initial recovery key (irreversible, can only be set once).
     * @param recoveryKeyHash keccak256 hash of a 28-character alphanumeric code (case-insensitive).
     */
    function setRecoveryKey(bytes32 recoveryKeyHash) external {
        if (_recoveryKeyHash[msg.sender] != bytes32(0)) revert RecoveryKeyAlreadySet();
        _recoveryKeyHash[msg.sender] = recoveryKeyHash;
        emit RecoveryKeyRotated(msg.sender, recoveryKeyHash);
    }

    /**
     * @notice Register the recovery wallet. Requires current code and rotates to a new code.
     * @param wallet The address of the new recovery wallet.
     * @param code The current recovery code (plain text, 28 alphanumeric).
     * @param newRecoveryKeyHash keccak256 hash of the next code (28 alphanumeric, case-insensitive).
     */
    function setRecoveryWallet(address wallet, string calldata code, bytes32 newRecoveryKeyHash) external {
        if (wallet == address(0)) revert InvalidCode();
        if (_recoveryWallet[msg.sender] != address(0)) revert RecoveryWalletAlreadySet();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryWallet[msg.sender] = wallet;
        emit RecoveryWalletSet(msg.sender, wallet);
    }

    /**
     * @notice Activate recovery mode. Requires current code and rotates to a new code.
     * @param code The current recovery code (plain text).
     * @param newRecoveryKeyHash keccak256 hash of the next code (28 alphanumeric, case-insensitive).
     */
    function activateRecoveryMode(string calldata code, bytes32 newRecoveryKeyHash) external {
        if (_recoveryWallet[msg.sender] == address(0)) revert InvalidCode();
        if (_recoveryModeActivated[msg.sender]) revert RecoveryWalletAlreadySet();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryModeActivated[msg.sender] = true;
        _isCompromised[msg.sender] = true;
        emit RecoveryModeActivated(msg.sender);
        emit AddressCompromised(msg.sender);
    }

    /**
     * @notice Change recovery wallet. Requires current code and rotates to a new code.
     * @param newWallet The new recovery wallet address.
     * @param code The current recovery code (plain text).
     * @param newRecoveryKeyHash keccak256 hash of the next code (28 alphanumeric, case-insensitive).
     */
    function changeRecoveryWallet(address newWallet, string calldata code, bytes32 newRecoveryKeyHash) external {
        if (newWallet == address(0)) revert InvalidCode();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryWallet[msg.sender] = newWallet;
        emit RecoveryWalletSet(msg.sender, newWallet);
    }

    /**
     * @notice Deactivate recovery mode. Requires current code and rotates to a new code.
     * @param code The current recovery code (plain text).
     * @param newRecoveryKeyHash keccak256 hash of the next code (28 alphanumeric, case-insensitive).
     */
    function deactivateRecoveryMode(string calldata code, bytes32 newRecoveryKeyHash) external {
        if (!_recoveryModeActivated[msg.sender]) revert NotInRecoveryMode();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryModeActivated[msg.sender] = false;
        emit RecoveryModeDeactivated(msg.sender);
    }

    // ====== Internal Logic ======

    /**
     * @dev Internal function for code validation and hash rotation. Enforces 28-char alphanumeric codes.
     * @param code The current (old) code, plain text.
     * @param newRecoveryKeyHash Hash of the next code.
     */
    function _rotateRecoveryKey(string calldata code, bytes32 newRecoveryKeyHash) internal {
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        if (!_isValidRecoveryCode(code)) revert InvalidCodeFormat();
        if (keccak256(abi.encodePacked(_normalizeCode(code))) != _recoveryKeyHash[msg.sender]) revert InvalidCode();
        if (newRecoveryKeyHash == bytes32(0) || newRecoveryKeyHash == _recoveryKeyHash[msg.sender]) revert InvalidCode();
        _recoveryKeyHash[msg.sender] = newRecoveryKeyHash;
        emit RecoveryKeyRotated(msg.sender, newRecoveryKeyHash);
    }

    /**
     * @dev Validate recovery code length and character set (A-Z, 0-9), 28 chars exactly, hyphens allowed for grouping.
     *      All hyphens will be ignored for hashing/comparison.
     */
    function _isValidRecoveryCode(string calldata code) internal pure returns (bool) {
        bytes calldata b = bytes(code);
        uint256 len = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "-") continue;
            if (
                !( (c >= "A" && c <= "Z") ||
                   (c >= "a" && c <= "z") ||
                   (c >= "0" && c <= "9")
                 )
            ) {
                return false;
            }
            len++;
        }
        return len == 28;
    }

    /**
     * @dev Normalize code: uppercase and remove hyphens. So codes like abcd-1234-xyzz... are always hashed as ABCD1234XYZZ...
     */
    function _normalizeCode(string calldata code) internal pure returns (string memory) {
        bytes calldata b = bytes(code);
        bytes memory normalized = new bytes(28);
        uint256 n = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "-") continue;
            // convert lowercase to uppercase (A-Z)
            if (c >= "a" && c <= "z") {
                normalized[n++] = bytes1(uint8(c) - 32);
            } else {
                normalized[n++] = c;
            }
            if (n == 28) break;
        }
        return string(normalized);
    }

    // ====== VIEW FUNCTIONS ======

    /// @notice Get registered recovery wallet for a user
    function getRecoveryWallet(address user) external view returns (address) {
        return _recoveryWallet[user];
    }

    /// @notice Is user in recovery mode?
    function isRecoveryModeActive(address user) external view returns (bool) {
        return _recoveryModeActivated[user];
    }

    /// @notice Has user marked address as compromised?
    function isCompromised(address user) external view returns (bool) {
        return _isCompromised[user];
    }

    /// @notice Get recovery key hash (for dApps, only returns hash)
    function getRecoveryKeyHash(address user) external view returns (bytes32) {
        return _recoveryKeyHash[user];
    }
}
