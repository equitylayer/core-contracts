// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec
pragma solidity ^0.8.35;

import {SharedHonkVerifier, Honk} from "./SharedHonkVerifier.sol";
import {IZKVerifier} from "../interfaces/IZKVerifier.sol";

uint256 constant N = 4096;
uint256 constant LOG_N = 12;
uint256 constant NUMBER_OF_PUBLIC_INPUTS = 13;
uint256 constant VK_HASH = 0x2884d98ff616e5f35b1ae991cd1bdcb96c2039cabaaf173f3ef0aad9992e5457;

library HonkVerificationKey {
    function loadVerificationKey() internal pure returns (Honk.VerificationKey memory) {
        Honk.VerificationKey memory vk = Honk.VerificationKey({
            circuitSize: uint256(4096),
            logCircuitSize: uint256(12),
            publicInputsSize: uint256(13),
            ql: Honk.G1Point({
                x: uint256(0x2cf5f29a82fdbf243b702a943d64484389fb9d82a08c8eaaf1e69039b47c368b),
                y: uint256(0x21c864bcf7a0c236ad9240c8b70c600222bb8f4032d44a26f8ac2e95e7fd5565)
            }),
            qr: Honk.G1Point({
                x: uint256(0x02a7147097e5ec8365b172f3508046ac38acacdad22ae4b8a9dc10d39e1d74bb),
                y: uint256(0x25f52f628585e88153ab7c12c3e90640a8c3c3ae435085f8ea95cbdaf54fd124)
            }),
            qo: Honk.G1Point({
                x: uint256(0x2a3e0bdf2ce294bca28528ca399f79247e65814b026559d1d3c26a2659d88a7d),
                y: uint256(0x0b9ba443c420564754207d3530701d5c3a5ec5da05931abea3046aadda05f8e6)
            }),
            q4: Honk.G1Point({
                x: uint256(0x278a673e25243d47e435c8485663e584357955bed0083efc8eaec2a939e3f013),
                y: uint256(0x1ef71a505b9697740c0e3e7fa845db25aac0b476c5999d73e8a72ee887848056)
            }),
            qm: Honk.G1Point({
                x: uint256(0x0971e01c35d45c574c21fcdb148a394370d5586219df90b788f5720ec280306e),
                y: uint256(0x2d849b9aea1a52e3d4fe2ac787a14f97b5ce79ca893e70b9d4f2361de136e345)
            }),
            qc: Honk.G1Point({
                x: uint256(0x03f5655f4a13cc0a03d2f2ba4a373a61318aee39d3fc396a11720dfa3ba511c3),
                y: uint256(0x26851941b267c2b01ea93ef1064017a92cd44ed6db308512bd0e9f661048571f)
            }),
            qLookup: Honk.G1Point({
                x: uint256(0x2ccf97777978aa36adcdd05588e03d4de649085cda7fe019d46d0ec179c56274),
                y: uint256(0x0973ebba2ca18abf3ad084c6fc0c7ef2dccadbc4f0cb96e4c98e950a23e2b847)
            }),
            qArith: Honk.G1Point({
                x: uint256(0x20d28a1e427ff6d8dcb542aed481a08413e14806c82cdadaa54eff464d0a7518),
                y: uint256(0x2730f729b7ded32f2e794987bc3b97951267d3d076d9e660bb5a321f048d48ee)
            }),
            qDeltaRange: Honk.G1Point({
                x: uint256(0x2e48daaad3303738d3fc8750739f775fbeffc574b064ac56c446b12bbc3a965f),
                y: uint256(0x138edf21cf1262c3d956e170d58b5504308ebebc2d9ee323e108cc37070cbfb0)
            }),
            qElliptic: Honk.G1Point({
                x: uint256(0x2ec4ec653cf279e7d0c014f54606eb49b81210d1c9faf5d6468a28e6ed15549c),
                y: uint256(0x2f5ef06aceb98b034a78f27663455679cbe69b06db08c6191c8445a401fca240)
            }),
            qMemory: Honk.G1Point({
                x: uint256(0x17d2320da7ccf19991c2f91d9d1b7472e8ded1ca5501acc080826be477639ff6),
                y: uint256(0x22f9d8e0ceeeae601c59ccfc174ed4769e493a1d72b85701d994b20cc3397b11)
            }),
            qNnf: Honk.G1Point({
                x: uint256(0x1cc8416a52f3dd1f30f2db2e5c820674b0f43cbbd2a4b90b211adea3bb6d5184),
                y: uint256(0x002b400ab445e2ad93643356e3032dc8a0bb5b092d9096f3a9d64ebe8515299f)
            }),
            qPoseidon2External: Honk.G1Point({
                x: uint256(0x1fcd1bb6ff7e40df2cc3a99540322b8fa1984615735dec6e1e16f342bfa3196a),
                y: uint256(0x04649de7b376111b89905207970f8b2f5fcedb749b6dc853a7e6c3edb486dba9)
            }),
            qPoseidon2Internal: Honk.G1Point({
                x: uint256(0x1efed083d760a511086ae699419af9edfcd76cf18946a52743ad98875c0933a7),
                y: uint256(0x16ac802b5e8c83105af72f4ed72e48b8e08f37facefecc0acf7b33b1da3c0d07)
            }),
            s1: Honk.G1Point({
                x: uint256(0x01734b05ee0899e1b1483e78cb930e56f35912fb6bca4899b35e76211b18499f),
                y: uint256(0x0c5f6ea65f7f7c537fa0e1c2d85bf6706d19ecda001d50996ed7ea2e67b6df8b)
            }),
            s2: Honk.G1Point({
                x: uint256(0x17257f4ef1dfc1873e5bd8a1a8ee64d1dffb1b960a9de1f983705798cb72ae26),
                y: uint256(0x05e66beaf2e335923966a13b873597a7646d185d7756b4699cde02e8dd7bfc3f)
            }),
            s3: Honk.G1Point({
                x: uint256(0x06b36df7d7a140e4491c854752b8af12b90f716f3a8e7e3d8060bb419f301d64),
                y: uint256(0x100d7e303e71a6850ed133b33ab1d01f67510e961dadb147b282de026bd45fdf)
            }),
            s4: Honk.G1Point({
                x: uint256(0x118582cb38c1a0696cfb145874a0b2140a178e02a5d1ece2f5631c78219d15c4),
                y: uint256(0x1d2af709c862823c917764a9c7bd9624b7886e1c2c112762f9ee3ab792c0dab2)
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
                x: uint256(0x2497cda47144dc65758b0a93ff89f842cc438cbe46a044fcd4781d85d28f04b8),
                y: uint256(0x100e6996aaa9501321216b6cd8cc4ccdce491e99ed6bdbe88af998872a189b23)
            }),
            id2: Honk.G1Point({
                x: uint256(0x2d287aafc8e499d00b43d39aa2e4dfbe68926c90b3f2f0a5d545bb950d29ff2f),
                y: uint256(0x0eec4fc77212ccf26403c3880250108c56346b4d5ad6ed4cb20698db3ae89396)
            }),
            id3: Honk.G1Point({
                x: uint256(0x0d06f09c4b542adc6e379c8b36417bf02b5227e0780f13ba273c8a1a8bf15f5d),
                y: uint256(0x0eb9816a6559a62d5f8930c51f6fd42b504e91f2ddd9562a67a3290c5afd4827)
            }),
            id4: Honk.G1Point({
                x: uint256(0x145690018361767713355a34185c08b42e696fa02c8d8ba024957cdb0caca923),
                y: uint256(0x2ec1fc4e382c65d5c8670b2fb0869867816308833b0846ee080a57ebe0bb02e4)
            }),
            lagrangeFirst: Honk.G1Point({
                x: uint256(0x0000000000000000000000000000000000000000000000000000000000000001),
                y: uint256(0x0000000000000000000000000000000000000000000000000000000000000002)
            }),
            lagrangeLast: Honk.G1Point({
                x: uint256(0x25894e4f744cdbf622778d3c1bf591af225781855208087a059e886a0076afaf),
                y: uint256(0x2449f0b614e482c197c99c7dd5cd8002cb5b9596be8a2ee3fe575033d67a5628)
            })
        });
        return vk;
    }
}

contract CnRepayVerifier is IZKVerifier {
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
