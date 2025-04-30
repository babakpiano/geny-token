// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title GenyDAO
/// @author compez.eth
/// @notice Manages Genyleap Improvement Proposals (GIP) for decentralized governance in the Genyleap ecosystem.
/// @dev Implements voting with 20% quorum for normal proposals and 50% for sensitive ones, 7-day voting period, and 2-day Timelock.
///      Proposing requires 0.1% (normal) or 1% (sensitive) of circulating supply; voting requires 256 tokens.
///      Circulating supply is calculated using GenyAllocation's released tokens. Investor labels enhance transparency.
///      Minimums and labels can be updated via GIP. Integrates with GenyAllocation and GenyBurnManager.
/// @custom:security-contact security@genyleap.com
contract GenyDAO is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token; // GENY token contract
    TimelockController public timelock; // Timelock for delayed execution
    address public burnManager; // GenyBurnManager for token burning
    address public allocationManager; // GenyAllocation for treasury management
    uint32 public minProposingPowerNormalPercent; // Basis points (0.1% = 10)
    uint32 public minProposingPowerSensitivePercent; // Basis points (1% = 100)
    uint256 public minVotingPower; // Minimum tokens to vote (256 tokens)
    uint256 public lastBurnTimestamp; // Last burn timestamp for cooldown

    /// @notice Investor label types for proposers
    enum InvestorLabel { None, Founder, CoreInvestor, CommunityAdvocate, StandardHolder }

    /// @dev Stores proposal details with optimized storage
    struct Proposal {
        address proposer;
        string description;
        uint48 startTime;
        uint48 endTime;
        uint96 forVotes;
        uint96 againstVotes;
        uint96 totalVotes;
        bool executed;
        bool isSensitive;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
    }

    mapping(uint256 => Proposal) public proposals; // Proposal ID to details
    mapping(uint256 => mapping(address => bool)) public hasVoted; // Tracks voting status
    mapping(address => InvestorLabel) public investorLabels; // Investor labels
    uint256 public proposalCount; // Total number of proposals

    // Constants
    uint32 private constant QUORUM_NORMAL = 20_00; // 20% (2000 basis points)
    uint32 private constant QUORUM_SENSITIVE = 50_00; // 50% (5000 basis points)
    uint48 private constant VOTING_PERIOD = 7 days;
    uint48 private constant BURN_COOLDOWN = 1 days;
    uint32 private constant BURN_MAX_PERCENT = 10_00; // 10% (1000 basis points)
    uint32 private constant MIN_PROPOSING_PERCENT_MIN = 1; // 0.01% (1 basis point)
    uint32 private constant MIN_PROPOSING_PERCENT_MAX = 1000; // 10% (1000 basis points)
    uint256 private constant MIN_VOTING_POWER_MIN = 25 * 1e18;
    uint256 private constant MIN_VOTING_POWER_MAX = 2560 * 1e18;

    /// @notice Emitted when a new GIP is created
    event ProposalCreated(uint256 indexed proposalId, address proposer, InvestorLabel proposerLabel, string description, bool isSensitive, uint48 startTime);
    /// @notice Emitted when a vote is cast
    event Voted(uint256 indexed proposalId, address voter, bool support, uint96 weight);
    /// @notice Emitted when a proposal is executed
    event ProposalExecuted(uint256 indexed proposalId);
    /// @notice Emitted when tokens are burned
    event TokensBurned(uint256 indexed proposalId, uint256 amount);
    /// @notice Emitted when proposing power percentage is updated
    event MinProposingPowerPercentUpdated(bool isSensitive, uint32 oldPercent, uint32 newPercent);
    /// @notice Emitted when minimum voting power is updated
    event MinVotingPowerUpdated(uint256 oldPower, uint256 newPower);
    /// @notice Emitted when an investor label is updated
    event InvestorLabelUpdated(address indexed investor, InvestorLabel oldLabel, InvestorLabel newLabel);

    constructor() { _disableInitializers(); }

    /// @notice Initializes the DAO contract
    /// @param _token Address of the GENY token contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    /// @param _burnManager Address of the GenyBurnManager contract
    /// @param _allocationManager Address of the GenyAllocation contract
    /// @param _timelock Address of the TimelockController contract
    function initialize(
        address _token,
        address _owner,
        address _burnManager,
        address _allocationManager,
        address _timelock
    ) external initializer {
        _validateAddresses(_token, _owner, _burnManager, _allocationManager, _timelock);

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        burnManager = _burnManager;
        allocationManager = _allocationManager;
        timelock = TimelockController(payable(_timelock));
        minProposingPowerNormalPercent = 10; // 0.1%
        minProposingPowerSensitivePercent = 100; // 1%
        minVotingPower = 256 * 1e18;
    }

    /// @notice Returns the circulating supply using GenyAllocation's released tokens
    /// @return The circulating supply in tokens
    function getCirculatingSupply() public view returns (uint256) {
        return IGenyAllocation(allocationManager).getTotalReleasedTokens();
    }

    /// @notice Returns the minimum proposing power for a proposal
    /// @param isSensitive True if the proposal is sensitive
    /// @return The minimum tokens required
    function getMinProposingPower(bool isSensitive) public view returns (uint256) {
        return (getCirculatingSupply() * (isSensitive ? minProposingPowerSensitivePercent : minProposingPowerNormalPercent)) / 1e4;
    }

    /// @notice Creates a new GIP
    /// @param description Proposal description
    /// @param isSensitive True if the proposal is sensitive
    /// @param targets Contract addresses to call
    /// @param values ETH values for each call
    /// @param calldatas Data for each call
    function createProposal(
        string memory description,
        bool isSensitive,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) external whenNotPaused {
        require(token.balanceOf(msg.sender) >= getMinProposingPower(isSensitive), "Insufficient proposing power");
        require(targets.length == values.length && values.length == calldatas.length, "Invalid proposal data");

        uint48 currentTime = uint48(block.timestamp);
        proposals[++proposalCount] = Proposal({
            proposer: msg.sender,
            description: description,
            startTime: currentTime,
            endTime: currentTime + VOTING_PERIOD,
            forVotes: 0,
            againstVotes: 0,
            totalVotes: 0,
            executed: false,
            isSensitive: isSensitive,
            targets: targets,
            values: values,
            calldatas: calldatas
        });

        emit ProposalCreated(proposalCount, msg.sender, investorLabels[msg.sender], description, isSensitive, currentTime);
    }

    /// @notice Casts a vote on a proposal
    /// @param proposalId The ID of the proposal
    /// @param support True for supporting, false for opposing
    function vote(uint256 proposalId, bool support) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.startTime && block.timestamp <= proposal.endTime, "Voting not active");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        uint96 weight = uint96(token.balanceOf(msg.sender));
        require(weight >= minVotingPower, "Insufficient voting power");

        hasVoted[proposalId][msg.sender] = true;
        proposal.totalVotes += weight;
        if (support) proposal.forVotes += weight;
        else proposal.againstVotes += weight;

        emit Voted(proposalId, msg.sender, support, weight);
    }

    /// @notice Executes a proposal after voting ends
    /// @param proposalId The ID of the proposal
    function executeProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "Voting not ended");
        require(!proposal.executed, "Already executed");
        require(proposal.forVotes > proposal.againstVotes, "Proposal rejected");

        uint32 quorumPercent = proposal.isSensitive ? QUORUM_SENSITIVE : QUORUM_NORMAL;
        require(proposal.totalVotes >= (getCirculatingSupply() * quorumPercent) / 1e4, "Quorum not met");

        proposal.executed = true;
        timelock.scheduleBatch(proposal.targets, proposal.values, proposal.calldatas, bytes32(proposalId), "GenyDAO Proposal Execution", 2 days);

        emit ProposalExecuted(proposalId);
    }

    /// @notice Updates the minimum proposing power percentage
    /// @param isSensitive True for sensitive proposals, false for normal
    /// @param newPercent New percentage (in basis points)
    function updateMinProposingPowerPercent(bool isSensitive, uint32 newPercent) external onlyGovernance {
        require(newPercent >= MIN_PROPOSING_PERCENT_MIN && newPercent <= MIN_PROPOSING_PERCENT_MAX, "Invalid proposing percent");
        if (isSensitive) {
            uint32 oldPercent = minProposingPowerSensitivePercent;
            minProposingPowerSensitivePercent = newPercent;
            emit MinProposingPowerPercentUpdated(true, oldPercent, newPercent);
        } else {
            uint32 oldPercent = minProposingPowerNormalPercent;
            minProposingPowerNormalPercent = newPercent;
            emit MinProposingPowerPercentUpdated(false, oldPercent, newPercent);
        }
    }

    /// @notice Updates the minimum voting power
    /// @param newPower New minimum voting power
    function updateMinVotingPower(uint256 newPower) external onlyGovernance {
        require(newPower >= MIN_VOTING_POWER_MIN && newPower <= MIN_VOTING_POWER_MAX, "Invalid voting power");
        emit MinVotingPowerUpdated(minVotingPower, newPower);
        minVotingPower = newPower;
    }

    /// @notice Assigns or updates an investor label by owner
    /// @param investor Address of the investor
    /// @param label New label to assign
    function setInvestorLabel(address investor, InvestorLabel label) external onlyOwner {
        _updateInvestorLabel(investor, label);
    }

    /// @notice Updates an investor label via GIP
    /// @param investor Address of the investor
    /// @param label New label to assign
    function updateInvestorLabel(address investor, InvestorLabel label) external onlyGovernance {
        _updateInvestorLabel(investor, label);
    }

    /// @notice Burns tokens from the treasury
    /// @param amount Amount of tokens to burn
    function burnTokens(uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp >= lastBurnTimestamp + BURN_COOLDOWN, "Burn cooldown active");
        require(amount <= (token.balanceOf(address(this)) * BURN_MAX_PERCENT) / 1e4, "Exceeds max burn limit");

        lastBurnTimestamp = block.timestamp;
        token.safeApprove(burnManager, amount);
        IGenyBurnManager(burnManager).burnFromContract(amount);

        emit TokensBurned(proposalCount, amount);
    }

    /// @notice Pauses the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Validates initialization addresses
    function _validateAddresses(address _token, address _owner, address _burnManager, address _allocationManager, address _timelock) private pure {
        require(_token != address(0) && _owner != address(0) && _burnManager != address(0) && _allocationManager != address(0) && _timelock != address(0), "Invalid address");
    }

    /// @dev Updates investor label with event emission
    function _updateInvestorLabel(address investor, InvestorLabel label) private {
        require(investor != address(0), "Invalid investor address");
        emit InvestorLabelUpdated(investor, investorLabels[investor], label);
        investorLabels[investor] = label;
    }

    modifier onlyGovernance() {
        require(msg.sender == address(timelock), "Caller is not the timelock");
        _;
    }
}

interface IGenyBurnManager {
    function burnFromContract(uint256 amount) external;
}

interface IGenyAllocation {
    function getTotalReleasedTokens() external view returns (uint256);
}