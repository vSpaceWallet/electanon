// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./SemaphoreOpt.sol";
import {PairBaseLib} from "../../libs/PairBaseLib.sol";

contract ZKPrivatePairVoting is SemaphoreOpt {
    event Proposed(
        uint256 indexed _id,
        address indexed _from,
        string _proposal
    );
    event StateChanged(
        States indexed _from,
        States indexed _to,
        uint256 _stateDeadline
    );
    event ProposersAdded(address indexed _sender, address[] proposers);
    event VoterIdCommitsAdded(
        address indexed _sender,
        uint256[] voterCommits,
        uint256 indexed _root
    );

    event VoterTreeReplaced(
        address indexed _sender,
        uint256[] voterCommits,
        uint256 indexed _root
    );

    enum States {
        Register,
        Proposal,
        Commit,
        Reveal,
        Completed
    }
    States state;

    uint256 constant MAX_PROPOSAL_CAP = 30;
    uint256 proposalIdCt;
    uint256 deadline;
    uint256 maxProposalCount;
    uint256 proposalLifetime;
    uint256 commitLifetime;
    uint256 revealLifetime;

    mapping(address => bool) proposers;
    uint256 proposerCount;
    mapping(uint256 => uint256) voteCounts;
    uint256 committedCount;
    uint256 votedCount;
    mapping(address => bytes32) secrets;
    uint256[] ranks;

    modifier deadlineNotPassed() {
        require(block.timestamp >= deadline, "State deadline is passed!");
        _;
    }

    modifier eligibleProposer() {
        require(proposers[msg.sender], "You're not eligible to propose!");
        _;
    }

    modifier atState(States _state) {
        require(state == _state, "Function cannot be called at this time.");
        _;
    }

    modifier atCompletedState() {
        require(isCompletedState(), "Function cannot be called at this time.");
        _;
    }

    // Perform timed transitions. Be sure to mention
    // this modifier first, otherwise the guards
    // will not take the new stage into account.
    modifier timedTransitions() {
        timedTransitionsHelper();
        // The other stages transition by transaction
        _;
    }

    constructor(
        uint256 _treeLevels,
        uint256 _maxProposalCount,
        uint256 _proposalLifetime,
        uint256 _commitLifetime,
        uint256 _revealLifetime
    ) SemaphoreOpt(_treeLevels) {
        require(
            maxProposalCount <= MAX_PROPOSAL_CAP,
            "maxProposalCount is too high!"
        );
        maxProposalCount = _maxProposalCount;
        proposalLifetime = _proposalLifetime;
        commitLifetime = _commitLifetime;
        revealLifetime = _revealLifetime;
        toState(States.Register);
    }

    function toState(States _state) internal {
        state = _state;
    }

    function toNextState() external {
        require(timedTransitionsHelper(), "Cannot change to next state!");
    }

    function toProposalState() external onlyOwner {
        require(state == States.Register, "Cannot change state to Proposal!");
        toState(States.Proposal);
        uint256 result = block.timestamp + proposalLifetime;
        deadline = result;
        emit StateChanged(States.Register, States.Proposal, result);
    }

    function toCommitState() internal {
        toState(States.Commit);
        uint256 result = block.timestamp + commitLifetime;
        deadline = result;
        emit StateChanged(States.Proposal, States.Commit, result);
    }

    function toRevealState() internal {
        toState(States.Reveal);
        uint256 result = block.timestamp + revealLifetime;
        deadline = result;
        emit StateChanged(States.Commit, States.Reveal, result);
    }

    function toCompletedState() internal {
        toState(States.Completed);
        emit StateChanged(States.Reveal, States.Completed, block.timestamp);
    }

    function addProposers(address[] calldata proposerList)
        external
        atState(States.Register)
        onlyOwner
    {
        for (uint256 i = 0; i < proposerList.length; i++) {
            _setupProposer(proposerList[i]);
        }
        proposerCount += proposerList.length;
        emit ProposersAdded(msg.sender, proposerList);
    }

    function addIdCommitments(
        uint256[] calldata _identityCommitments,
        uint256 _root
    ) external atState(States.Register) onlyOwner {
        insertLeaves(_identityCommitments, _root);
        emit VoterIdCommitsAdded(msg.sender, _identityCommitments, _root);
    }

    function replaceIdCommitmentsTree(
        uint256[] calldata _identityCommitments,
        uint256 _root
    ) external atState(States.Register) onlyOwner {
        replaceTree(_identityCommitments, _root);
        emit VoterTreeReplaced(msg.sender, _identityCommitments, _root);
    }

    function propose(string calldata _proposal)
        external
        timedTransitions
        atState(States.Proposal)
        eligibleProposer
    {
        uint256 ptrProposalIdCt = proposalIdCt++ + 1;
        proposers[msg.sender] = false;
        emit Proposed(proposalIdCt, msg.sender, _proposal);
        if (
            ptrProposalIdCt == maxProposalCount ||
            ptrProposalIdCt == proposerCount
        ) {
            toCommitState();
        }
    }

    function commitVote(
        bytes32 _secretHash,
        uint256[8] calldata _proof,
        uint256 _nullifiersHash
    ) external timedTransitions atState(States.Commit) {
        require(_secretHash != 0, "secret hash cannot be 0");
        broadcastSignal(_secretHash, _proof, _nullifiersHash);
        secrets[msg.sender] = _secretHash;
        committedCount++;
        if (committedCount == getLeavesNum()) {
            toRevealState();
        }
    }

    function revealVote(uint256 _voteRank, bytes32 _salt)
        external
        timedTransitions
        atState(States.Reveal)
    {
        require(secrets[msg.sender] != 0, "You have no pending vote commit!");
        require(
            keccak256(abi.encodePacked(_voteRank, _salt)) ==
                secrets[msg.sender],
            "Wrong credentials"
        );
        if (voteCounts[_voteRank] == 0) {
            // might not be needed (instead use perm ids)
            ranks.push(_voteRank);
        }
        voteCounts[_voteRank]++;
        committedCount--;
        delete secrets[msg.sender];
        if (committedCount == 0) {
            toCompletedState();
        }
    }

    function checkVote(uint256 _voteRank, uint256 _salt)
        external
        view
        returns (bool)
    {
        return
            keccak256(abi.encodePacked(_voteRank, _salt)) ==
            secrets[msg.sender];
    }

    /* solhint-disable */
    //https://math.libretexts.org/Bookshelves/Applied_Mathematics/Book%3A_College_Mathematics_for_Everyday_Life_(Inigo_et_al)
    //https://en.wikipedia.org/wiki/Ranked_pairs
    /* solhint-enable */
    function electionResult() external view atCompletedState returns (uint256) {
        uint256 matrixSize = proposalIdCt;
        uint256[] memory rankIds = ranks;
        return PairBaseLib.calculateResult(matrixSize, rankIds, voteCounts);
    }

    function isEligibleProposer(address account) external view returns (bool) {
        return proposers[account];
    }

    function currentState() external view returns (string memory) {
        if (state == States.Register) return "Register";
        if (state == States.Proposal) return "Proposal";
        if (state == States.Commit) return "Commit";
        if (state == States.Reveal) return "Reveal";
        if (isCompletedState()) return "Completed";
        return "";
    }

    function currentRealState() external view returns (string memory) {
        if (isCompletedState()) return "Completed";
        if (isRevealState()) return "Reveal";
        if (isCommitState()) return "Commit";
        if (state == States.Proposal) return "Proposal";
        if (state == States.Register) return "Register";
        return "";
    }

    function getRank(uint256[] calldata vec) external pure returns (uint256) {
        uint256 n = vec.length;
        uint256[] memory v = new uint256[](n);
        uint256[] memory inv = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            v[i] = vec[i];
            inv[vec[i] - 1] = i + 1;
        }
        uint256 r = PairBaseLib._mr_rank1(n, v, inv);
        return r;
    }

    /// PRIVATE CODE

    // Perform timed transitions. Be sure to mention
    // this modifier first, otherwise the guards
    // will not take the new stage into account.
    function timedTransitionsHelper() private returns (bool) {
        if (changableToCommit()) {
            toCommitState();
            return true;
        } else if (changableToReveal()) {
            toRevealState();
            return true;
        } else if (changableToCompleted()) {
            toCompletedState();
            return true;
        } else {
            return false;
        }
    }

    function isCompletedState() private view returns (bool) {
        return state == States.Completed || changableToCompleted();
    }

    function isCommitState() private view returns (bool) {
        return state == States.Commit || changableToCommit();
    }

    function isRevealState() private view returns (bool) {
        return state == States.Reveal || changableToReveal();
    }

    function changableToCommit() private view returns (bool) {
        return state == States.Proposal && block.timestamp >= deadline;
    }

    function changableToReveal() private view returns (bool) {
        return state == States.Commit && block.timestamp >= deadline;
    }

    function changableToCompleted() private view returns (bool) {
        return state == States.Reveal && block.timestamp >= deadline;
    }

    function currentProposals() public view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](proposalIdCt);
        for (uint256 i = 0; i < proposalIdCt; i++) {
            result[i] = i + 1;
        }
        return result;
    }

    function _setupProposer(address account) private {
        require(proposers[account] == false, "Proposer is added already.");
        proposers[account] = true;
    }
}
