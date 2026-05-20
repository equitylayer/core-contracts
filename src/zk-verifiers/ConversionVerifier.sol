// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec
pragma solidity ^0.8.35;

import {SharedHonkVerifier, Honk} from "./SharedHonkVerifier.sol";
import {IZKVerifier} from "../interfaces/IZKVerifier.sol";
uint256 constant N = 65536;
uint256 constant LOG_N = 16;
uint256 constant NUMBER_OF_PUBLIC_INPUTS = 140;
uint256 constant VK_HASH = 0x09b72e6e80f5c2bca3de205aef01271d1cb445323105948d3307ca0867748e02;

library HonkVerificationKey {
    function loadVerificationKey() internal pure returns (Honk.VerificationKey memory) {
        Honk.VerificationKey memory vk = Honk.VerificationKey({
            circuitSize: uint256(65536),
            logCircuitSize: uint256(16),
            publicInputsSize: uint256(140),
            ql: Honk.G1Point({
                x: uint256(0x2ec4a82a80f1748b2f37d70ab2356b4c21f5edaaeed31ea52f12f5eb8ef149eb),
                y: uint256(0x148b6622d45388a5637a2fc844a62b7bd56e8c52eeb3d7158611d5b9f5a202c2)
            }),
            qr: Honk.G1Point({
                x: uint256(0x24fc841702ebfda46f1b186f1975cccb766892bd262208aea098feff6ee1808a),
                y: uint256(0x1ea7bef9f2a48d9a93baf4bb83a56d823cb410199cdc6a8693984efedac55936)
            }),
            qo: Honk.G1Point({
                x: uint256(0x0877050f70a9bf3a98a63cfbd5069d9d7141d55ac6c1fcceb126b432c380ae7e),
                y: uint256(0x2a33a10cd849ad09450571f9098b38c2788c683c66719e4d8b9f10757284ebe0)
            }),
            q4: Honk.G1Point({
                x: uint256(0x093f1a9bc7ca8152543a821795231f50212d3722518a1dc2a84b65dd7922bc4c),
                y: uint256(0x12435880921bd6f26316018fe159f91330449381de0db3d5d2b8b7e50fe2b053)
            }),
            qm: Honk.G1Point({
                x: uint256(0x14c6aee4843afcfb6f714fa2dbaae6661ba52271f0306fe0e8c32ff564b6781f),
                y: uint256(0x0809c06ba714dd5ee895c3f88302d822560cdd186956012f255d93bfa58df32d)
            }),
            qc: Honk.G1Point({
                x: uint256(0x0807cff8dc1adf0122b78fc41d2a3422b816c388d7a1fe9ac87541175cb87d04),
                y: uint256(0x28ccdff03adf91bf998e845d313ad7e59496a027bda1c4276ee9f4fe76c62f06)
            }),
            qLookup: Honk.G1Point({
                x: uint256(0x01f6df13f92ec32147b542adae85f53c90392f25e0973671cab7612132bf3e50),
                y: uint256(0x0a426392b5f6e1bb12c511bf5b7e56471a15bddbcf6077497a882debb5c6bf3d)
            }),
            qArith: Honk.G1Point({
                x: uint256(0x1af92fd25f5899869209c897625e4442506e6ab8d3d5d585897282b8d801b4cc),
                y: uint256(0x2ee935697f7642d608b392642b6d6ea001060688361d0d69724950242199450d)
            }),
            qDeltaRange: Honk.G1Point({
                x: uint256(0x05418e09e16066234d44d59030257558d1f942a3af29f3d28a3df07471c0b33e),
                y: uint256(0x1b6cdedbd20b09e1b6894fbee88e106c13b3fab67d1dedb28a72541a2337a350)
            }),
            qElliptic: Honk.G1Point({
                x: uint256(0x10bf378aa88e3c4f6ac1833d1c3ccf05dcd11b37fe015bc9f205a4e2784ccb9e),
                y: uint256(0x1019fdcdcf9acb51ef70758a018ebf3eef1fc4207efe05019a51ade385cf512e)
            }),
            qMemory: Honk.G1Point({
                x: uint256(0x08b214e7fe0d5f9a9e9f7195681f665da272e75580488666a721c8cfc63c252f),
                y: uint256(0x1cf87223ed0052e8b37dc50d26f82fa608edffc607bc0e3e89c93408c7a8df3b)
            }),
            qNnf: Honk.G1Point({
                x: uint256(0x1364b97b8c3024c232fd61792695e911455a5c6c8ce948cf9bf1c2bf287771d6),
                y: uint256(0x1bc08f624698766b02ed52f99fdd206b4cb845a86c37fd0b202ff48b337ec2a8)
            }),
            qPoseidon2External: Honk.G1Point({
                x: uint256(0x2e7ac5a2b0a38402559260083c974dc1ed05327d646c0cfb81a54e457bff7adf),
                y: uint256(0x1569cb337cd7687bdb46a713654b2cb44cf14f89ba86d0f438f370c97396d312)
            }),
            qPoseidon2Internal: Honk.G1Point({
                x: uint256(0x27940b1042fad986a28631f4f2dcb9bf9ea907a192740414b79a696e31fdcad3),
                y: uint256(0x29feb60bb66f0b709f7772d1b62bda183bd64be702dcbbcfde34f3902955cb93)
            }),
            s1: Honk.G1Point({
                x: uint256(0x239dff988843ec3e9e739e58d9d49ca235580c33993197e0c55e7adfb7e42808),
                y: uint256(0x0427c1b73fc23a68f625d6c056a7e1e873090688cde1a2e24ec4deee8f6d2fc1)
            }),
            s2: Honk.G1Point({
                x: uint256(0x03a5f31d40d5a5f1761a1074195f15e09c9fc80f5f0877f005f19583b4da6910),
                y: uint256(0x13f80d8743d893547690cf4e0216da86e76689ed0acabd815540001fa41b09cf)
            }),
            s3: Honk.G1Point({
                x: uint256(0x1bcfb39a45360b211bccdc86766dace86051cfdfc90db3272fec219de3f493dc),
                y: uint256(0x037dad555e7c76d145b6ea6891bcc0fea7b20f616b9bb48ad612eaa7d3174818)
            }),
            s4: Honk.G1Point({
                x: uint256(0x0f841c9bb3b1c3d0071f45e25762f6b8743fc37c32417fc80aa17a1e5d47e3f9),
                y: uint256(0x0a490cb2f0d41f97073805c042fcbf35d42e671940b2c1503404adf139dea62b)
            }),
            t1: Honk.G1Point({
                x: uint256(0x099e3bd5a0a00ab7fe18040105b9b395b5d8b7b4a63b05df652b0d10ef146d26),
                y: uint256(0x0015b8d2515d76e2ccec99dcd194592129af3a637f5a622a32440f860d1e2a7f)
            }),
            t2: Honk.G1Point({
                x: uint256(0x1b917517920bad3d8bc01c9595092a222b888108dc25d1aa450e0b4bc212c37e),
                y: uint256(0x305e8992b148eedb22e6e992077a84482141c7ebe42000a1d58ccb74381f6d19)
            }),
            t3: Honk.G1Point({
                x: uint256(0x16465a5ccbb550cd2c63bd58116fe47c86847618681dc29d8a9363ab7c40e1c3),
                y: uint256(0x2e24d420fbf9508ed31de692db477b439973ac12d7ca796d6fe98ca40e6ca6b7)
            }),
            t4: Honk.G1Point({
                x: uint256(0x043d063b130adfb37342af45d0155a28edd1a7e46c840d9c943fdf45521c64ce),
                y: uint256(0x261522c4089330646aff96736194949330952ae74c573d1686d9cb4a00733854)
            }),
            id1: Honk.G1Point({
                x: uint256(0x26c988749dbe4d67eadd47f6d3417b6c7b219e8866f10ce9b99704bcf4482b63),
                y: uint256(0x0c6b679e81aad3566cbe877e854b729afca4a2e319b4635e978c8ab6bb212e73)
            }),
            id2: Honk.G1Point({
                x: uint256(0x0d02d6695fbdd6ba50c3d8f5264468e99dd748effd31117ad4e118814baf13a0),
                y: uint256(0x2d62252cf634d3352ffccacf6ff4d375e2bcafd17efeefa205815b80c18981c5)
            }),
            id3: Honk.G1Point({
                x: uint256(0x2ee3b0fe3bb2caa46a86acbac7c114a8a143b0a3d7b417da21d81c31267636e9),
                y: uint256(0x1382266f5e444d6a4e89775834ba04a28c39e20d302d5556122ffd9e5e54d698)
            }),
            id4: Honk.G1Point({
                x: uint256(0x1def76679399eb80860b0ec9bce913bb6d247f5f161ac2edcf6684fc5e8029e0),
                y: uint256(0x1f22ef5d5095f3f11f616e1895dc5a36bd932a0afe1ab4be18671f7feabee0be)
            }),
            lagrangeFirst: Honk.G1Point({
                x: uint256(0x0000000000000000000000000000000000000000000000000000000000000001),
                y: uint256(0x0000000000000000000000000000000000000000000000000000000000000002)
            }),
            lagrangeLast: Honk.G1Point({
                x: uint256(0x2a5b0a37f027b589d5a2464552de75ef0e39b3046d6f508fa502e961818a9528),
                y: uint256(0x0767502734bb005fb2dde97133081ed273caf2c682795a101013390aa1a96ebf)
            })
        });
        return vk;
    }
}

contract ConversionVerifier is IZKVerifier {
    SharedHonkVerifier public immutable shared;

    constructor(SharedHonkVerifier _shared) {
        shared = _shared;
    }

    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool) {
        return shared.verify(
            proof, publicInputs, HonkVerificationKey.loadVerificationKey(), LOG_N, VK_HASH, NUMBER_OF_PUBLIC_INPUTS
        );
    }
}
