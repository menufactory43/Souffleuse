#!/usr/bin/env node

import fs from "node:fs";

const binaryPath =
    process.argv[2] ?? "/Applications/Cotypist.app/Contents/MacOS/Cotypist";

const descriptors = [
    { name: "SequenceCandidate", offset: 0x7b9fe4 },
    { name: "CompletionResult", offset: 0x7ba0a0 },
    { name: "SamplerState", offset: 0x7ba6b0 },
    { name: "BranchConfiguration", offset: 0x7ba748 },
    { name: "SequenceState", offset: 0x7ba770 },
];

const bytes = fs.readFileSync(binaryPath);

function relativeTarget(pointerOffset) {
    return pointerOffset + bytes.readInt32LE(pointerOffset);
}

function readCString(offset, maximumLength = 256) {
    const end = Math.min(bytes.length, offset + maximumLength);
    let cursor = offset;
    while (cursor < end && bytes[cursor] !== 0) cursor += 1;
    return bytes.subarray(offset, cursor).toString("utf8");
}

function readSymbolicString(offset, maximumLength = 96) {
    const end = Math.min(bytes.length, offset + maximumLength);
    const parts = [];
    for (let cursor = offset; cursor < end && bytes[cursor] !== 0; cursor += 1) {
        const byte = bytes[cursor];
        parts.push(
            byte >= 0x20 && byte <= 0x7e
                ? String.fromCharCode(byte)
                : `\\x${byte.toString(16).padStart(2, "0")}`,
        );
    }
    return parts.join("");
}

function parseDescriptor({ name, offset }) {
    const recordSize = bytes.readUInt16LE(offset + 10);
    const fieldCount = bytes.readUInt32LE(offset + 12);
    const fields = [];

    for (let index = 0; index < fieldCount; index += 1) {
        const recordOffset = offset + 16 + index * recordSize;
        const typePointerOffset = recordOffset + 4;
        const namePointerOffset = recordOffset + 8;
        fields.push({
            index,
            name: readCString(relativeTarget(namePointerOffset)),
            mangledType: readSymbolicString(relativeTarget(typePointerOffset)),
        });
    }

    return {
        name,
        descriptorOffset: `0x${offset.toString(16)}`,
        kind: bytes.readUInt16LE(offset + 8),
        recordSize,
        fieldCount,
        fields,
    };
}

console.log(JSON.stringify({
    binaryPath,
    descriptors: descriptors.map(parseDescriptor),
}, null, 2));
