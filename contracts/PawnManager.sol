pragma solidity ^0.4.24;


import "./rcn/interfaces/Cosigner.sol";
import "./rcn/interfaces/Engine.sol";
import "./rcn/interfaces/Token.sol";
import "./interfaces/ERC721.sol";

import "./rcn/utils/BytesUtils.sol";
import "./rcn/utils/Ownable.sol";

import "./ERC721Base.sol";


contract IBundle is ERC721Base {
    function depositBatch(uint256 _packageId, ERC721[] tokens, uint256[] ids) external returns (bool);
    function depositTokenBatch(uint256 _packageId, ERC721 token, uint256[] ids) external returns (bool);
    function deposit(uint256 _packageId, ERC721 token, uint256 tokenId) external returns (bool);
    function content(uint256 id) external view returns (address[] tokens, uint256[] ids);
    function create() public returns (uint256 id);
    function withdraw(uint256 packageId, ERC721 token, uint256 tokenId, address to) public returns (bool);
}


contract IPoach is ERC721Base {
    function getPair(uint poachId) public view returns(address, uint, bool);
    function create(Token token, uint256 amount) public payable returns (uint256 id);
    function destroy(uint256 id) public returns (bool);
}


contract NanoLoanEngine is Engine {
    function createLoan(address _oracleContract, address _borrower, bytes32 _currency,
        uint256 _amount, uint256 _interestRate, uint256 _interestRatePunitory, uint256 _duesIn,
        uint256 _cancelableAt, uint256 _expirationRequest, string _metadata) public returns (uint256);

    function registerApprove(bytes32 identifier, uint8 v, bytes32 r, bytes32 s) public returns (bool);
    function getAmount(uint index) public view returns (uint256);
    function getIdentifier(uint index) public view returns (bytes32);
    function identifierToIndex(bytes32 signature) public view returns (uint256);
}


/**
    @notice The contract is used to handle all the lifetime of a pawn. The borrower can

    Implements the Cosigner interface of RCN, and when is tied to a loan it creates a new ERC721
      to handle the ownership of the pawn.

    When the loan is resolved (paid, pardoned or defaulted), the pawn with his tokens can be recovered.
*/
contract PawnManager is Cosigner, ERC721Base, BytesUtils, Ownable {
    using SafeMath for uint256;

    address constant internal ETH = 0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;
    NanoLoanEngine public nanoLoanEngine;
    IBundle public bundle;
    IPoach public poach;

    event NewPawn(address borrower, uint256 loanId, uint256 packageId, uint256 pawnId);
    event RequestedPawn(uint256 pawnId, address borrower, address engine, uint256 loanId, uint256 packageId);
    event StartedPawn(uint256 pawnId);
    event CanceledPawn(address from, address to, uint256 pawnId);
    event PaidPawn(address from, uint256 pawnId);
    event DefaultedPawn(uint256 pawnId);
    // Relates packageIds to pawnIds
    mapping(uint256 => uint256) public pawnByPackageId;
    // Relates engine address to loanId to pawnIds
    mapping(address => mapping(uint256 => uint256)) public loanToLiability;

    Pawn[] public pawns;

    struct Pawn {
        address owner;
        Engine engine;
        uint256 loanId;
        uint256 packageId;
        Status status;
    }

    enum Status { Pending, Ongoing, Canceled, Paid, Defaulted }

    constructor(NanoLoanEngine _nanoLoanEngine, IBundle _bundle, IPoach _poach) public {
        nanoLoanEngine = _nanoLoanEngine;
        bundle = _bundle;
        poach = _poach;
        pawns.length++;
    }

    // Getters
    function getLiability(Engine engine, uint256 loanId) public view returns(uint256) { return loanToLiability[engine][loanId]; }
    function getPawnId(uint256 packageId) public view returns(uint256) { return pawnByPackageId[packageId]; }
    // Struct pawn getters
    function getPawnOwner(uint256 pawnId) public view returns(address) { return pawns[pawnId].owner; }
    function getPawnEngine(uint256 pawnId) public view returns(address) { return pawns[pawnId].engine; }
    function getPawnLoanId(uint256 pawnId) public view returns(uint256) { return pawns[pawnId].loanId; }
    function getPawnPackageId(uint256 pawnId) public view returns(uint256) { return pawns[pawnId].packageId; }
    function getPawnStatus(uint256 pawnId) public view returns(Status) { return pawns[pawnId].status; }

    /**
        @dev Creates a loan using an array of parameters

        @param _oracle  Oracle of loan
        @param _currency Currency of loan
        @param params 0 - Ammount
                      1 - Interest rate
                      2 - Interest rate punitory
                      3 - Dues in
                      4 - Cancelable at
                      5 - Expiration of request

        @param metadata Loan metadata

        @return Id of the loan

    */
    function createLoan(
        Oracle _oracle,
        bytes32 _currency,
        uint256[6] memory params,
        string metadata
    ) internal returns (uint256) {
        return nanoLoanEngine.createLoan(
            _oracle,
            msg.sender,
            _currency,
            params[0],
            params[1],
            params[2],
            params[3],
            params[4],
            params[5],
            metadata
        );
    }

    /**
        @notice Request a loan and attachs a pawn request

        @dev Requires the loan signed by the borrower
            The length of _tokens and _amounts should be equal
             also length of _erc721s and _ids

        @param _oracle  Oracle of loan
        @param _currency Currency of loan
        @param loanParams   0 - Ammount
                            1 - Interest rate
                            2 - Interest rate punitory
                            3 - Dues in
                            4 - Cancelable at
                            5 - Expiration of request
        @param metadata Loan metadata
        @param v Loan signature by the borrower
        @param r Loan signature by the borrower
        @param s Loan signature by the borrower

        @param _tokens Array of ERC20 contract addresses
        @param _amounts Array of tokens amounts
        @param _erc721s Array of ERC721 contract addresses
        @param _ids Array of non fungible token ids

        @return pawnId The id of the pawn
        @return packageId The id of the package
    */
    function requestPawn(
        Oracle _oracle,
        bytes32 _currency,
        uint256[6] loanParams,
        string metadata,
        uint8 v,
        bytes32 r,
        bytes32 s,
        //ERC20
        Token[] _tokens,
        uint256[] _amounts,
        //ERC721
        ERC721[] _erc721s,
        uint256[] _ids
    ) public payable returns (uint256 pawnId, uint256 packageId) {
        uint256 loanId = createLoan(_oracle, _currency, loanParams, metadata);
        require(nanoLoanEngine.registerApprove(nanoLoanEngine.getIdentifier(loanId), v, r, s));

        (pawnId, packageId) = requestPawnId(nanoLoanEngine, loanId, _tokens, _amounts, _erc721s, _ids);

        emit NewPawn(msg.sender, loanId, packageId, pawnId);
    }

    /**
        @notice Requests a pawn with a loan identifier

        @dev The loan should exist in the designated engine
             The length of _tokens and _amounts should be equal
              also length of _erc721s and _ids

        @param engine RCN Engine
        @param loanIdentifier Identifier of the loan asociated with the pawn

        @param _tokens Array of ERC20 contract addresses
        @param _amounts Array of tokens amounts
        @param _erc721s Array of ERC721 contract addresses
        @param _ids Array of non fungible token ids

        @return pawnId The id of the pawn
        @return packageId The id of the package
    */
    function requestPawnWithLoanIdentifier(
        NanoLoanEngine engine,
        bytes32 loanIdentifier,
        Token[] _tokens,
        uint256[] _amounts,
        ERC721[] _erc721s,
        uint256[] _ids
    ) public payable returns (uint256 pawnId, uint256 packageId) {
        return requestPawnId(engine, engine.identifierToIndex(loanIdentifier), _tokens, _amounts, _erc721s, _ids);
    }

    /**
        @notice Request a pawn to buy a new loan

        @dev The loan should exist in the designated engine
             The length of _tokens and _amounts should be equal
              also length of _erc721s and _ids

        @param engine RCN Engine
        @param loanId Id of the loan asociated with the pawn

        @param _tokens Array of ERC20 contract addresses
        @param _amounts Array of tokens amounts
        @param _erc721s Array of ERC721 contract addresses
        @param _ids Array of non fungible token ids

        @return pawnId The id of the pawn
        @return packageId The id of the package
    */
    function requestPawnId(
        Engine engine,
        uint256 loanId,
        Token[] _tokens,
        uint256[] _amounts,
        ERC721[] _erc721s,
        uint256[] _ids
    ) public payable returns (uint256 pawnId, uint256 packageId) {
        // Validate the associated loan
        address borrower = engine.getBorrower(loanId);
        require(engine.getStatus(loanId) == Engine.Status.initial);
        require(msg.sender == borrower || msg.sender == engine.getCreator(loanId));
        require(engine.isApproved(loanId));
        require(loanToLiability[engine][loanId] == 0);

        packageId = createPackage(_tokens, _amounts, _erc721s, _ids);

        // Create the liability
        pawnId = pawns.push(Pawn({
            owner:     borrower,
            engine:    engine,
            loanId:    loanId,
            packageId: packageId,
            status:    Status.Pending
        })) - 1;

        loanToLiability[engine][loanId] = pawnId;

        emit RequestedPawn({
            pawnId:    pawnId,
            borrower:  borrower,
            engine:    engine,
            loanId:    loanId,
            packageId: packageId
        });
    }

    /**
        @notice Create a package
        @dev The length of _tokens and _amounts should be equal also
              length of _erc721s and _ids
              The sum of the all amounts of ether should be send

        @param _tokens Array of ERC20 contract addresses
        @param _amounts Array of tokens amounts
        @param _erc721s Array of ERC721 contract addresses
        @param _ids Array of non fungible token ids

        @return the index of package on array of bundle contract
    */
    function createPackage(
        Token[] _tokens,
        uint256[] _amounts,
        ERC721[] _erc721s,
        uint256[] _ids
    ) internal returns(uint256 packageId) {
        uint256 tokensLength = _tokens.length;
        uint256 erc721sLength = _erc721s.length;
        require(tokensLength == _amounts.length && erc721sLength == _ids.length);

        packageId = bundle.create();
        uint256 i = 0;
        uint256 poachId;
        uint256 totEth;

        for (; i < tokensLength; i++) {
            if (address(_tokens[i]) != ETH) {
                require(_tokens[i].transferFrom(msg.sender, this, _amounts[i]));
                require(_tokens[i].approve(poach, _amounts[i]));
                poachId = poach.create(_tokens[i], _amounts[i]);
            } else {
                poachId = poach.create.value(_amounts[i])(_tokens[i], _amounts[i]);
                totEth = totEth.add(_amounts[i]);
            }

            require(poach.approve(bundle, poachId));
            bundle.deposit(packageId, ERC721(poach), poachId);
        }
        require(totEth == msg.value);

        for (i = 0; i < erc721sLength; i++) {
            require(_erc721s[i].transferFrom(msg.sender, this, _ids[i]));
            require(_erc721s[i].approve(bundle, _ids[i]));
        }
        bundle.depositBatch(packageId, _erc721s, _ids);
    }

    /**
        @notice Cancels an existing pawn and withdraw all tokens
        @dev The pawn status should be pending

        @param _pawnId Id of the pawn
        @param _to The new owner
        @param _asBundle If true only transfer the package, if false transfer all tokens

        @return true If the operation was executed
    */
    function cancelPawn(uint256 _pawnId, address _to, bool _asBundle) public returns (bool) {
        Pawn storage pawn = pawns[_pawnId];

        // Only the owner of the pawn and if the pawn is pending
        require(msg.sender == pawn.owner, "Only the owner can cancel the pawn");
        require(pawn.status == Status.Pending, "The pawn is not pending");

        pawn.status = Status.Canceled;

        _transferAsset(pawn.packageId, _to, _asBundle);

        emit CanceledPawn(msg.sender, _to, _pawnId);
        return true;
    }

    /**
        @dev Use to claim eth to the poach
    */
    function () external payable {
        require(msg.sender == address(poach));
    }

    //
    // Implements cosigner
    //
    uint256 private constant I_PAWN_ID = 0;

    /**
        @notice Returns the cost of the cosigner

        This cosigner does not have any risk or maintenance cost, so its free.

        @return 0, because it's free
    */
    function cost(address , uint256 , bytes , bytes ) public view returns (uint256) {
        return 0;
    }

    /**
        @notice Request the cosign of a loan

        Emits an ERC721 to manage the ownership of the pawn property.

        @param _engine Engine of the loan
        @param _index Index of the loan
        @param _data Data with the pawn id

        @return True if the cosign was performed
    */
    function requestCosign(Engine _engine, uint256 _index, bytes _data, bytes ) public returns (bool) {
        require(msg.sender == address(_engine), "the sender its not the Engine");
        uint256 pawnId = uint256(readBytes32(_data, I_PAWN_ID));
        Pawn storage pawn = pawns[pawnId];

        // Validate that the loan matches with the pawn
        // and the pawn is still pending
        require(pawn.engine == _engine, "Engine does not match");
        require(pawn.loanId == _index, "Loan id does not match");
        require(pawn.status == Status.Pending, "Pawn is not pending");

        pawn.status = Status.Ongoing;

        // Mint pawn ERC721 Token
        _generate(pawnId, pawn.owner);

        // Cosign contract
        require(_engine.cosign(_index, 0), "Error performing cosign");

        // Save pawn id registry
        pawnByPackageId[pawn.packageId] = pawnId;

        // Emit pawn event
        emit StartedPawn(pawnId);

        return true;
    }

    function url() public view returns (string) {
        return "";
    }

    /**
        @notice Defines a custom logic that determines if a loan is defaulted or not.

        @param _engine RCN Engines
        @param _index Index of the loan

        @return true if the loan is considered defaulted
    */
    function isDefaulted(Engine _engine, uint256 _index) public view returns (bool) {
        return _engine.getStatus(_index) == Engine.Status.lent && 
            _engine.getDueTime(_index).add(7 days) <= block.timestamp;
    }

    /**
        @notice Claims the pawn when the loan status is resolved
        and transfers the ownership of the package to which corresponds.

        @dev Deletes the pawn ERC721

        @param _engine RCN Engine
        @param _loanId Loan ID

        @return true If the claim succeded
    */
    function claim(address _engine, uint256 _loanId, bytes ) public returns (bool) {
        return _claim(_engine, _loanId, true);
    }

    /**
        @notice Claims the pawn when the loan status is resolved and transfer all tokens to which corresponds.

        @dev Deletes the pawn ERC721

        @param _engine RCN Engine
        @param _loanId Loan ID

        @return true If the claim succeded
    */
    function claimWithdraw(address _engine, uint256 _loanId) public returns (bool) {
        return _claim(_engine, _loanId, false);
    }

    /**
        @notice Claims the pawn when the loan status is resolved and transfer all tokens to which corresponds.

        @dev Deletes the pawn ERC721

        @param _engine RCN Engine
        @param _loanId Loan ID
        @param _asBundle If true only transfer the package, if false transfer all tokens

        @return true If the claim succeded
    */
    function _claim(address _engine, uint256 _loanId, bool _asBundle) internal returns(bool){
        uint256 pawnId = loanToLiability[_engine][_loanId];
        Pawn storage pawn = pawns[pawnId];
        // Validate that the pawn wasn't claimed
        require(pawn.status == Status.Ongoing, "Pawn not ongoing");
        require(pawn.loanId == _loanId, "Pawn don't match loan id");

        if (pawn.engine.getStatus(_loanId) == Engine.Status.paid || pawn.engine.getStatus(_loanId) == Engine.Status.destroyed) {
            // The pawn is paid
            require(_isAuthorized(msg.sender, pawnId), "Sender not authorized");

            pawn.status = Status.Paid;

            _transferAsset(pawn.packageId, msg.sender, _asBundle);

            emit PaidPawn(msg.sender, pawnId);
        } else {
            if (isDefaulted(pawn.engine, _loanId)) {
                // The pawn is defaulted
                require(msg.sender == pawn.engine.ownerOf(_loanId), "Sender not lender");

                pawn.status = Status.Defaulted;

                _transferAsset(pawn.packageId, msg.sender, _asBundle);

                emit DefaultedPawn(pawnId);
            } else {
                revert("Pawn not defaulted/paid");
            }
        }

        // ERC721 Delete asset
        _destroy(pawnId);

        // Delete pawn id registry
        delete pawnByPackageId[pawn.packageId];

        return true;
    }

    function _transferAsset(uint _packageId, address _to, bool _asBundle) internal returns(bool) {
        if (_asBundle) {
            // Transfer the package back to the _to
            require(bundle.safeTransferFrom(this, _to, _packageId));
        } else {
            // Transfer all tokens to the _to
            require(_withdrawAll(_packageId, _to));
        }

        return true;
    }

    /**
        @notice Transfer all the ERC721 and ERC20 of an package back to the beneficiary

        @dev If the currency its ether and the destiny its a contract, execute the payable deposit()

        @param _packageId Id of the pawn
        @param _beneficiary Beneficiary of tokens

        @return true If the operation was executed
    */
    function _withdrawAll(uint256 _packageId, address _beneficiary) internal returns(bool) {
        address[] memory tokens;
        uint256[] memory ids;
        (tokens, ids) = bundle.content(_packageId);
        uint256 tokensLength = tokens.length;
        // for ERC20 tokens
        address addr;
        uint256 amount;

        for (uint i = 0; i < tokensLength; i++) {
            if (tokens[i] != address(poach)) {
                // for a ERC721 token
                bundle.withdraw(_packageId, ERC721(tokens[i]), ids[i], _beneficiary);
            } else { // for a ERC20 token
                bundle.withdraw(_packageId, ERC721(tokens[i]), ids[i], address(this));
                (addr, amount,) = poach.getPair(ids[i]);
                require(poach.destroy(ids[i]), "Fail destroy");
                if (addr != ETH)
                    require(Token(addr).transfer(_beneficiary, amount));
                else
                    _beneficiary.transfer(amount);
            }
        }
        return true;
    }
}
