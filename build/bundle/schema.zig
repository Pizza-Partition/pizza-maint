//! JSON wire types for the supported Sigstore bundle and provenance profile.
const time_encoding = @import("utils").time;

pub const Validity = struct {
    start: []const u8,
    end: ?[]const u8 = null,

    pub fn validate(self: Validity, time: u64) !void {
        if (time < try time_encoding.timestamp(self.start)) return error.InvalidAttestation;
        if (self.end) |end| if (time > try time_encoding.timestamp(end)) return error.InvalidAttestation;
    }
};

pub const Certificate = struct { rawBytes: []const u8 };
pub const LogId = struct { keyId: []const u8 };
pub const Log = struct {
    hashAlgorithm: []const u8,
    logId: LogId,
    publicKey: struct { rawBytes: []const u8, keyDetails: []const u8, validFor: Validity },
};
pub const TrustRoot = struct {
    tlogs: []const Log,
    ctlogs: []const Log,
    certificateAuthorities: []const struct {
        certChain: struct { certificates: []const Certificate },
        validFor: Validity,
    },
};
pub const InclusionProof = struct {
    logIndex: []const u8,
    treeSize: []const u8,
    rootHash: []const u8,
    hashes: []const []const u8,
    checkpoint: struct { envelope: []const u8 },
};
pub const LogEntry = struct {
    kindVersion: struct { kind: []const u8, version: []const u8 },
    integratedTime: []const u8,
    logIndex: []const u8,
    logId: LogId,
    canonicalizedBody: []const u8,
    inclusionPromise: struct { signedEntryTimestamp: []const u8 },
    inclusionProof: InclusionProof,
};
pub const Bundle = struct {
    mediaType: []const u8,
    verificationMaterial: struct { certificate: Certificate, tlogEntries: []const LogEntry },
    dsseEnvelope: struct {
        payloadType: []const u8,
        payload: []const u8,
        signatures: []const struct { sig: []const u8 },
    },
};
pub const LogBody = struct {
    kind: []const u8,
    apiVersion: []const u8,
    spec: struct {
        payloadHash: struct { algorithm: []const u8, value: []const u8 },
        signatures: []const struct { signature: []const u8, verifier: []const u8 },
    },
};
pub const Statement = struct {
    _type: []const u8,
    predicateType: []const u8,
    subject: []const struct { name: []const u8, digest: struct { sha256: []const u8 } },
    predicate: struct {
        buildDefinition: struct {
            buildType: []const u8,
            externalParameters: struct { workflow: struct { repository: []const u8, ref: []const u8, path: []const u8 } },
        },
        runDetails: struct { builder: struct { id: []const u8 } },
    },
};
