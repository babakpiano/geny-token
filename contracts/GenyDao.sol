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
/// @notice A simple governance contract for the Genyleap ecosystem, managing Genyleap Improvement Proposals (GIP).
/// @dev Implements voting with 20% quorum for normal proposals and 50% for sensitive ones, 7-day voting period, and 2-day Timelock.
///      Proposing requires 0.1% of circulating supply for normal and 1% for sensitive proposals. Voting requires 256 tokens.
///      Investor labels (Founder, CoreInvestor, CommunityAdvocate, StandardHolder) are assigned for transparency.
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
    uint256 public minProposingPowerNormalPercent; // Percent of circulating supply for normal GIP (0.1%)
    uint256 public minProposingPowerSensitivePercent; // Percent of circulating supply for sensitive GIP (1%)
    uint256 public minVotingPower; // Minimum tokens to vote (256 tokens)

    /// @notice Investor label types for proposers
    enum InvestorLabel {
        None, // Default, no label
        Founder, // Project founders
        CoreInvestor, // Major long-term investors
        CommunityAdvocate, // Active community supporters
        StandardHolder // Standard token holders
    }

    struct Proposal {
        address proposer;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalVotes;
        bool executed;
        bool isSensitive; // True for sensitive proposals
        address[] targets; // Contracts to call
        uint256[] values; // ETH values for calls
        bytes[] calldatas; // Call data for execution
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => InvestorLabel) public investorLabels; // Investor labels for proposers
    uint256 public proposalCount;

    // Constants
    uint256 private constant QUORUM_NORMAL = 20; // 20% quorum for normal proposals
    uint256 private constant QUORUM_SENSITIVE = 50; // 50% quorum for sensitive proposals
    uint256 private constant VOTING_PERIOD = 7 days; // 7 days voting period
    uint256 private constant BURN_COOLDOWN = 1 days; // 24-hour cooldown for burns
    uint256 private constant BURN_MAX_PERCENT = 10; // Max 10% of treasury per burn
    uint256 private constant MIN_PROPOSING_PERCENT_MIN = 0.01 * 100; // Minimum 0.01% (1 basis point)
    uint256 private constant MIN_PROPOSING_PERCENT_MAX = 10 * 100; // Maximum 10% (1000 basis points)
    uint256 private constant MIN_VOTING_POWER_MIN = 25 * 10**18; // Minimum allowed voting power
    uint256 private constant MIN_VOTING_POWER_MAX = 2_560 * 10**18; // Maximum allowed voting power

    // Last burn timestamp for cooldown
    uint256 public lastBurnTimestamp;

    event ProposalCreated(
        uint256 indexed proposalId,
        address proposer,
        InvestorLabel proposerLabel,
        string description,
        bool isSensitive,
        uint256 startTime,
        uint256 endTime
    );
    event Voted(uint256 indexed proposalId, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event TokensBurned(uint256 indexed proposalId, uint256 amount);
    event MinProposingPowerNormalPercentUpdated(uint256 oldPercent, uint256 newPercent);
    event MinProposingPowerSensitivePercentUpdated(uint256 oldPercent, uint256 newPercent);
    event MinVotingPowerUpdated(uint256 oldPower, uint256 newPower);
    event InvestorLabelUpdated(address indexed investor, InvestorLabel oldLabel, InvestorLabel newLabel);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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
        require(_token != address(0), "Invalid token address");
        require(_owner != address(0), "Invalid owner address");
        require(_burnManager != address(0), "Invalid burn manager address");
        require(_allocationManager != address(0), "Invalid allocation manager address");
        require(_timelock != address(0), "Invalid timelock address");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        burnManager = _burnManager;
        allocationManager = _allocationManager;
        timelock = TimelockController(payable(_timelock));
        minProposingPowerNormalPercent = 0.1 * 100; // 0.1% (10 basis points)
        minProposingPowerSensitivePercent = 1 * 100; // 1% (100 basis points)
        minVotingPower = 256 * 10**18; // 256 tokens
    }

    /// @notice Returns the minimum proposing power for a proposal
    /// @param isSensitive True if the proposal is sensitive
    /// @return The minimum tokens required
    function getMinProposingPower(bool isSensitive) public view returns (uint256) {
        uint256 circulatingSupply = token.totalSupply(); // Approximation of circulating supply
        uint256 percent = isSensitive ? minProposingPowerSensitivePercent : minProposingPowerNormalPercent;
        return (circulatingSupply * percent) / (100 * 100); // Convert basis points to tokens
    }

    /// @notice Creates a new GIP (Genyleap Improvement Proposal)
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
        uint256 requiredPower = getMinProposingPower(isSensitive);
        require(token.balanceOf(msg.sender) >= requiredPower, "Insufficient proposing power");
        require(targets.length == values.length && values.length == calldatas.length, "Invalid proposal data");

        proposalCount++;
        InvestorLabel proposerLabel = investorLabels[msg.sender];
        proposals[proposalCount] = Proposal({
            proposer: msg.sender,
            description: description,
            startTime: block.timestamp,
            endTime: block.timestamp + VOTING_PERIOD,
            forVotes: 0,
            againstVotes: 0,
            totalVotes: 0,
            executed: false,
            isSensitive: isSensitive,
            targets: targets,
            values: values,
            calldatas: calldatas
        });

        emit ProposalCreated(proposalCount, msg.sender, proposerLabel, description, isSensitive, block.timestamp, block.timestamp + VOTING_PERIOD);
    }

    /// @notice Votes on a proposal
    /// @param proposalId The ID of the proposal
    /// @param support True for supporting, false for opposing
    function vote(uint256 proposalId, bool support) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.startTime && block.timestamp <= proposal.endTime, "Voting not active");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        uint256 weight = token.balanceOf(msg.sender);
        require(weight >= minVotingPower, "Insufficient voting power");

        hasVoted[proposalId][msg.sender] = true;
        proposal.totalVotes += weight;
        if (support) {
            proposal.forVotes += weight;
        } else {
            proposal.againstVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    /// @notice Executes a proposal after voting ends
    /// @param proposalId The ID of the proposal
    function executeProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "Voting not ended");
        require(!proposal.executed, "Already executed");
        require(proposal.forVotes > proposal.againstVotes, "Proposal rejected");

        // Check quorum (20% for normal, 50% for sensitive)
        uint256 circulatingSupply = token.totalSupply(); // Approximation of circulating supply
        uint256 quorumPercent = proposal.isSensitive ? QUORUM_SENSITIVE : QUORUM_NORMAL;
        require(proposal.totalVotes >= (circulatingSupply * quorumPercent) / 100, "Quorum not met");

        proposal.executed = true;

        // Schedule execution via Timelock
        timelock.scheduleBatch(
            proposal.targets,
            proposal.values,
            proposal.calldatas,
            bytes32(proposalId),
            "GenyDAO Proposal Execution",
            2 days // 2-day Timelock delay
        );

        emit ProposalExecuted(proposalId);
    }

    /// @notice Updates the minimum proposing power percentage for normal proposals via a GIP
    /// @param newPercent New percentage (in basis points)
    function updateMinProposingPowerNormalPercent(uint256 newPercent) external onlyGovernance {
        require(newPercent >= MIN_PROPOSING_PERCENT_MIN && newPercent <= MIN_PROPOSING_PERCENT_MAX, "Invalid proposing percent");
        uint256 oldPercent = minProposingPowerNormalPercent;
        minProposingPowerNormalPercent = newPercent;
        emit MinProposingPowerNormalPercentUpdated(oldPercent, newPercent);
    }

    /// @notice Updates the minimum proposing power percentage for sensitive proposals via a GIP
    /// @param newPercent New percentage (in basis points)
    function updateMinProposingPowerSensitivePercent(uint256 newPercent) external onlyGovernance {
        require(newPercent >= MIN_PROPOSING_PERCENT_MIN && newPercent <= MIN_PROPOSING_PERCENT_MAX, "Invalid proposing percent");
        uint256 oldPercent = minProposingPowerSensitivePercent;
        minProposingPowerSensitivePercent = newPercent;
        emit MinProposingPowerSensitivePercentUpdated(oldPercent, newPercent);
    }

    /// @notice Updates the minimum voting power via a GIP
    /// @param newPower New minimum voting power
    function updateMinVotingPower(uint256 newPower) external onlyGovernance {
        require(newPower >= MIN_VOTING_POWER_MIN && newPower <= MIN_VOTING_POWER_MAX, "Invalid voting power");
        uint256 oldPower = minVotingPower;
        minVotingPower = newPower;
        emit MinVotingPowerUpdated(oldPower, newPower);
    }

    /// @notice Assigns or updates an investor label
    /// @param investor Address of the investor
    /// @param label New label to assign
    function setInvestorLabel(address investor, InvestorLabel label) external onlyOwner {
        require(investor != address(0), "Invalid investor address");
        InvestorLabel oldLabel = investorLabels[investor];
        investorLabels[investor] = label;
        emit InvestorLabelUpdated(investor, oldLabel, label);
    }

    /// @notice Updates an investor label via a GIP
    /// @param investor Address of the investor
    /// @param label New label to assign
    function updateInvestorLabel(address investor, InvestorLabel label) external onlyGovernance {
        require(investor != address(0), "Invalid investor address");
        InvestorLabel oldLabel = investorLabels[investor];
        investorLabels[investor] = label;
        emit InvestorLabelUpdated(investor, oldLabel, label);
    }

    /// @notice Burns tokens from the treasury
    /// @param amount Amount of tokens to burn
    function burnTokens(uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp >= lastBurnTimestamp + BURN_COOLDOWN, "Burn cooldown active");
        require(amount <= (token.balanceOf(address(this)) * BURN_MAX_PERCENT) / 100, "Exceeds max burn limit");

        lastBurnTimestamp = block.timestamp;
        token.safeApprove(burnManager, amount);
        IGenyBurnManager(burnManager).burnFromContract(amount);

        emit TokensBurned(proposalCount, amount);
    }

    /// @notice Pauses the DAO in emergencies
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the DAO
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Modifier to restrict functions to governance (via Timelock)
    modifier onlyGovernance() {
        require(msg.sender == address(timelock), "Caller is not the timelock");
        _;
    }
}

interface IGenyBurnManager {
    function burnFromContract(uint256 amount) external;
}