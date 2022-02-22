/* SPDX-License-Identifier: BUSL-1.1 */
/* Copyright © 2021 Fragcolor Pte. Ltd. */

pragma solidity ^0.8.7;

import "openzeppelin-solidity/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-solidity/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-solidity/contracts/utils/structs/EnumerableSet.sol";
import "openzeppelin-solidity/contracts/utils/Counters.sol";
import "openzeppelin-solidity/contracts/utils/Create2.sol";
import "openzeppelin-solidity/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "openzeppelin-solidity/contracts/utils/cryptography/ECDSA.sol";
import "./Ownable.sol";
import "./IEntity.sol";
import "./IVault.sol";
import "./IUtility.sol";
import "./RoyaltiesReceiver.sol";
import "./ClonesWithCalldata.sol";
import "./UnstructuredStorage.sol";

struct StakeData {
    // Pack to 32 bytes
    // ALWAYS ADD TO THE END
    uint256 amount;
    uint256 blockStart;
    uint256 blockUnlock;
}

// this contract uses proxy
/// @title This contract holds all the Proto-Fragments
/// @dev The Royalty Payment Logic is implemented in `RoyaltiesReceiever`
contract Fragment is
    ERC721Enumerable,
    Ownable,
    Initializable,
    RoyaltiesReceiver,
    UnstructuredStorage
{
    function name() public view virtual override returns (string memory) {
        return "Asset Store";
    }

    function symbol() public view virtual override returns (string memory) {
        return "AS";
    }

    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using Counters for Counters.Counter;

    // sidechain will listen to those, side chain deals with rewards allocations etc
    event Stake(
        bytes32 indexed fragmentHash,
        address indexed owner,
        uint256 amount
    );

    // a new wild entity appeared on the grid
    // this is necessary to make the link with the sidechain
    event Spawn(
        bytes32 indexed fragmentHash,
        address entityContract,
        address vaultContract
    );

    // Unstructured storage slots
    bytes32 private constant SLOT_entityLogic =
        keccak256("fragcolor.fragment.entityLogic");
    bytes32 private constant SLOT_vaultLogic =
        keccak256("fragcolor.fragment.vaultLogic");
    bytes32 private constant SLOT_utilityLibrary =
        keccak256("fragcolor.fragment.utilityLibrary");
    bytes32 private constant SLOT_controller =
        keccak256("fragcolor.fragment.controller");

    // list of referencing fragments to resolve dependency trees
    bytes32 private constant FRAGMENT_ATTACH_NONCE =
        keccak256("fragcolor.fragment.attach.nonce");
    bytes32 private constant FRAGMENT_ATTACH_AUTHS =
        keccak256("fragcolor.fragment.attach.nonce");
    // Use a human readable counter for IDs
    bytes32 private constant FRAGMENT_COUNTER =
        keccak256("fragcolor.fragment.counter");
    // Token ID -> Fragment Hash
    bytes32 private constant FRAGMENT_FRAGMENTS_ID2HASH =
        keccak256("fragcolor.fragment.fragments");
    // Token ID -> Fragment Hash (¿Shouldn't this be Fragment Hash -> Token ID?)
    bytes32 private constant FRAGMENT_FRAGMENTS_HASH2ID =
        keccak256("fragcolor.fragment.fragments");
    // keep track of rezzed entitites
    bytes32 private constant FRAGMENT_ENTITIES =
        keccak256("fragcolor.fragment.entities");

    constructor() ERC721("", "") Ownable() {
        // NOT INVOKED IF PROXIED
        setupRoyalties(payable(0), FRAGMENT_ROYALTIES_BPS);
    }

    modifier fragmentOwnerOnly(uint256 fragmentId) {
        require(
            _exists(fragmentId) && (msg.sender == ownerOf(fragmentId)),
            "Fragment: only the owner of the fragment can execute this operation"
        );
        _;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            _supportsInterface(interfaceId) ||
            super.supportsInterface(interfaceId);
    }

    function bootstrap() public payable initializer {
        // Ownable
        Ownable._bootstrap();
        // Others
        _setAddress(SLOT_controller, owner());
        _setAddress(
            SLOT_utilityLibrary,
            address(0x87A26d575DA6d8e2993EAD77f8f6CD12CAd361bC)
        );
        _setAddress(
            SLOT_entityLogic,
            address(0x5d90907E6081F0b1F20d49F1dE7C7066Ea044769)
        );
        _setAddress(
            SLOT_vaultLogic,
            address(0xA439872b04aD580d9D573E41fD28a693B4B97515)
        );
        setupRoyalties(payable(owner()), FRAGMENT_ROYALTIES_BPS);
    }

    /// @notice Loads the Address of the Utility Library from Storage
    function getUtilityLibrary() public view returns (address addr) {
        bytes32 slot = SLOT_utilityLibrary;
        assembly {
            addr := sload(slot)
        }
    }

    function getController() public view returns (address addr) {
        bytes32 slot = SLOT_controller;
        assembly {
            addr := sload(slot)
        }
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(_exists(tokenId), "Fragment: URI query for nonexistent token");
        IUtility ut = IUtility(getUtilityLibrary());
        return ut.buildFragmentMetadata(hashOf(tokenId));
    }

    function contractURI() public view returns (string memory) {
        IUtility ut = IUtility(getUtilityLibrary());
        return ut.buildFragmentRootMetadata(owner(), FRAGMENT_ROYALTIES_BPS);
    }

    /// @notice Get the Token ID of Fragment Hash `fragmentHash`
    /// @param fragmentHash - The Fragment Hash
    function idOf(bytes32 fragmentHash) external view returns (uint256) {
        uint256[1] storage s;
        bytes32 sslot = bytes32(
            uint256(
                keccak256(
                    abi.encodePacked(FRAGMENT_FRAGMENTS_HASH2ID, fragmentHash)
                )
            )
        );
        assembly {
            s.slot := sslot
        }

        return s[0];
    }

    /// @notice Get the Fragment Hash of Token ID `fragmentId`
    /// @param fragmentId - The Token ID
    function hashOf(uint256 fragmentId) public view returns (bytes32) {
        bytes32[1] storage s;
        bytes32 sslot = bytes32(
            uint256(
                keccak256(
                    abi.encodePacked(FRAGMENT_FRAGMENTS_ID2HASH, fragmentId)
                )
            )
        );
        assembly {
            s.slot := sslot
        }

        return s[0];
    }

    function getEntities(uint256 fragmentId)
        external
        view
        returns (address[] memory entities)
    {
        EnumerableSet.AddressSet[1] storage s;
        bytes32 slot = bytes32(
            uint256(keccak256(abi.encodePacked(FRAGMENT_ENTITIES, fragmentId)))
        );
        assembly {
            s.slot := slot
        }

        uint256 len = s[0].length();
        entities = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            entities[i] = s[0].at(i);
        }
    }

    function isEntityOf(address addr, uint256 fragmentId)
        external
        view
        returns (bool)
    {
        EnumerableSet.AddressSet[1] storage s;
        bytes32 slot = bytes32(
            uint256(keccak256(abi.encodePacked(FRAGMENT_ENTITIES, fragmentId)))
        );
        assembly {
            s.slot := slot
        }

        return s[0].contains(addr);
    }

    /// @notice Returns the current chain’s EIP-155 unique identifier
    function _getChainId() private view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    /// @notice Allows the Owner of this Contract to add an Authorizer (i.e Fragnova's Blockchain's Off-Chain Validator)
    function addAuth(address addr) external onlyOwner {
        EnumerableSet.AddressSet[1] storage auths;
        bytes32 slot = bytes32(
            uint256(keccak256(abi.encodePacked(FRAGMENT_ATTACH_AUTHS)))
        );
        assembly {
            auths.slot := slot
        }
        auths[0].add(addr);
    }

    /// @notice Allows the Owner of this Contract to remove an Authorizer (i.e Fragnova's Blockchain's Off-Chain Validator)
    function delAuth(address addr) external onlyOwner {
        EnumerableSet.AddressSet[1] storage auths;
        bytes32 slot = bytes32(
            uint256(keccak256(abi.encodePacked(FRAGMENT_ATTACH_AUTHS)))
        );
        assembly {
            auths.slot := slot
        }
        auths[0].remove(addr);
    }

    /// @notice Attaches a Proto-Fragment from Fragnova's Blockchain to this Smart Contract
    /// @param fragmentHash - The Proto-Fragment ID to attach
    /// @param signature - The signature provided by Fragnova's Blockahin's Off-Chain Validator to validate this attach request
    /// @dev Verifies if the authorizer signed the message.
    /// Then, it  mints an ERC-721 Token (where the ID is the one plus the uint256 stored in `uint256(keccak256(abi.encodePacked(FRAGMENT_COUNTER)))`)
    /// and gives its ownership to `msg.sender`
    function attach(bytes32 fragmentHash, bytes calldata signature) external {
        require(!_exists(uint256(fragmentHash)), "Fragment already attached");

        uint64[1] storage nonce;
        // ¿I wonder why we there is only one authorizer?
        EnumerableSet.AddressSet[1] storage auths;
        Counters.Counter[1] storage tokenIds;
        // read from unstructured storage
        {
            bytes32 slot = bytes32(
                uint256(
                    keccak256(
                        abi.encodePacked(FRAGMENT_ATTACH_NONCE, msg.sender)
                    )
                )
            );
            assembly {
                // Make `nonce` array point to storage slot `slot`
                nonce.slot := slot
            }
        }
        {
            bytes32 slot = bytes32(
                uint256(keccak256(abi.encodePacked(FRAGMENT_ATTACH_AUTHS)))
            );
            assembly {
                // Make `auths` array point to storage slot `slot`
                auths.slot := slot
            }
        }
        {
            bytes32 slot = bytes32(
                uint256(keccak256(abi.encodePacked(FRAGMENT_COUNTER)))
            );
            assembly {
            // Make `tokenIds` array point to storage slot `slot`
                tokenIds.slot := slot
            }
        }

        // increment nonce
        nonce[0]++;

        // Authenticate this operation
        {
            // Returns a hash (of a hash) that will be later verified with `signature`
            bytes32 hash = ECDSA.toEthSignedMessageHash(
                keccak256(
                    abi.encodePacked(
                        fragmentHash,
                        _getChainId(),
                        msg.sender,
                        nonce[0]
                    )
                )
            );

            // Verify whether the hash was signed by `signature` and return public address of signer
            address auth = ECDSA.recover(hash, signature);

            require(auths[0].contains(auth), "Invalid signature");
        }

        tokenIds[0].increment();
        uint256 tokenId = tokenIds[0].current();

        // Store to Token ID 2 Fragment Hash table
        {
            bytes32[1] storage fragmentHashStorage;
            bytes32 slot = bytes32(
                uint256(
                    keccak256(
                        abi.encodePacked(FRAGMENT_FRAGMENTS_ID2HASH, tokenId)
                    )
                )
            );
            assembly {
                fragmentHashStorage.slot := slot
            }
            /// @dev Stores fragmentHash in `abi.encodePacked(FRAGMENT_FRAGMENTS_ID2HASH, tokenId)`
            fragmentHashStorage[0] = fragmentHash;
        }

        // Store to Fragment Hash 2 Token ID table
        {
            uint256[1] storage fragmentIDStorage;
            bytes32 slot = bytes32(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            FRAGMENT_FRAGMENTS_HASH2ID,
                            fragmentHash
                        )
                    )
                )
            );
            assembly {
                fragmentIDStorage.slot := slot
            }
            require(fragmentIDStorage[0] == 0, "Fragment already attached");
            /// @dev Stores tokenId in `abi.encodePacked(FRAGMENT_FRAGMENTS_HASH2ID, fragmentHash)`
            fragmentIDStorage[0] = tokenId;
        }

        _mint(msg.sender, tokenId);
    }

    /// @notice Creates a Fragment/Entity using a Proto-Fragment with Token ID `fragmentID`. Note: Only the owner of the Proto-Fragment can call this function
    /// @param fragmentId - The Token ID of the Proto-Fragment
    /// @param tokenName - The name to give the Fragment/Entity
    /// @param tokenSymbol - The symbol to give the Fragment/Entity
    /// @param unique - ¿
    /// @param updateable - ¿
    /// @param maxSupply - ¿
    function spawn(
        uint256 fragmentId,
        string memory tokenName,
        string memory tokenSymbol,
        bool unique,
        bool updateable,
        uint256 maxSupply
    )
        external
        fragmentOwnerOnly(fragmentId)
        returns (address entity, address vault)
    {
        bytes32 fragmentHash = hashOf(fragmentId);
        {
            bytes memory ptr = new bytes(32);
            assembly {
                mstore(add(ptr, 0x20), fragmentHash)
            }
            // Create and Deploy an Entity Smart Contract
            entity = ClonesWithCallData.cloneWithCallDataProvision(
                getAddress(SLOT_entityLogic),
                ptr
            );
            // Create and Deploy a Vault Smart Contract
            vault = ClonesWithCallData.cloneWithCallDataProvision(
                getAddress(SLOT_vaultLogic),
                ptr
            );
        }

        // entity
        {
            // Create a Struct that represents the Fragment/Entity
            FragmentInitData memory params = FragmentInitData(
                fragmentId,
                maxSupply,
                address(this),
                payable(vault),
                unique,
                updateable
            );

            // Call the de-facto constructor of the Entity Smart Contract and pass in the information about how we want the Fragment/Entity to be
            IEntity(entity).bootstrap(tokenName, tokenSymbol, params);

            // keep track of this new contract
            EnumerableSet.AddressSet[1] storage s;
            bytes32 slot = bytes32(
                uint256(
                    keccak256(abi.encodePacked(FRAGMENT_ENTITIES, fragmentId))
                )
            );
            assembly {
                // Make `s` array point to storage slot `slot`
                s.slot := slot
            }
            // Add `entity` to the AddressSet in `s[0]`
            s[0].add(entity);
        }

        // vault
        {
            // Call the de-facto constructor of the Vault Smart Contract and pass in the information
            // about the address of the Fragment/Entity Contract and the address of this contract (i.e the address of the Proto-Fragment Contract)
            IVault(payable(vault)).bootstrap(entity, address(this));
        }

        // emit events
        emit Spawn(fragmentHash, entity, vault);
    }


    function transferOwnership(address newOwner) public override onlyOwner {
        setupRoyalties(payable(newOwner), FRAGMENT_ROYALTIES_BPS);
        super.transferOwnership(newOwner);
    }

    /*
        TODO Decentralization.
        For now we keep control of this but in the future we want to have it controlled by decentralized votes
        Useful to remove spam and abuse of the system.
        Notice that referencing works will still work! We on purpose don't clean up data for now.
        Even staking and all still works.
        This literally just removes the ability to trade it and removes it from showing on portals like OpenSea.
    */
    function banish(uint256[] memory fragmentIds) external onlyOwner {
        for (uint256 i = 0; i < fragmentIds.length; i++) {
            _burn(fragmentIds[i]);
        }
    }

    /*
        Useful to remove spam and abuse of the system.
        Notice that referencing works will still work! We on purpose don't clean up data for now.
        Even staking and all still works.
        This literally just removes the ability to trade it and removes it from showing on portals like OpenSea.
    */
    function burn(uint256 fragmentId) external fragmentOwnerOnly(fragmentId) {
        _burn(fragmentId);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
    }

    function recoverETH(uint256 amount) external onlyOwner {
        payable(owner()).transfer(amount);
    }
}
