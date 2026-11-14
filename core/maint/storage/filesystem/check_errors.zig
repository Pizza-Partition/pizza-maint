//! Known filesystem check failures. Resource, device and unknown errors propagate.
const std = @import("std");
pub fn contains(comptime Errors: type, err: anyerror) bool {
    inline for (@typeInfo(Errors).error_set.error_names.?) |name| {
        if (err == @field(Errors, name)) return true;
    }
    return false;
}

pub const Fat = error{
    FatAmbiguousBoot,
    FatAmbiguousTables,
    FatBackupBoot,
    FatBadClusterConflict,
    FatBrokenChain,
    FatChainCycle,
    FatCrossLink,
    FatDanglingReference,
    FatDirtyVolume,
    FatDuplicateName,
    FatFileLength,
    FatFsInfo,
    FatInvalidActiveTable,
    FatInvalidBoot,
    FatInvalidCluster,
    FatInvalidDirectoryEntry,
    FatInvalidDotEntry,
    FatInvalidGeometry,
    FatInvalidLink,
    FatInvalidLongName,
    FatInvalidMedia,
    FatInvalidResizeDirection,
    FatInvalidResizeSize,
    FatInvalidTable,
    FatInvalidVolumeLabel,
    FatNotFat32,
    FatOrphanChain,
    FatPartitionOffsetOverflow,
    FatRecoveryDirectoryFull,
    FatReservedEntry,
    FatResizeTooSmall,
    FatSurfaceScanRequired,
    FatTablesDiffer,
    FatUnsupportedClusterSize,
    FatUnsupportedVersion,
};

pub const Ntfs = error{
    NtfsAmbiguousBoot,
    NtfsBackupBoot,
    NtfsBitmapMismatch,
    NtfsClusterCrossLink,
    NtfsHibernated,
    NtfsIncompleteMetadata,
    NtfsInvalidAttribute,
    NtfsInvalidBitmap,
    NtfsInvalidBoot,
    NtfsInvalidCreateSize,
    NtfsInvalidFixup,
    NtfsInvalidGeometry,
    NtfsInvalidIo,
    NtfsInvalidMetadata,
    NtfsInvalidMft,
    NtfsInvalidResizeDirection,
    NtfsInvalidResizeSize,
    NtfsInvalidRunlist,
    NtfsInvalidSeek,
    NtfsInvalidVolumeLabel,
    NtfsJournalRecoveryRequired,
    NtfsMetadataReservationRequired,
    NtfsMissingMft,
    NtfsMissingMirror,
    NtfsPartitionOffsetOverflow,
    NtfsRecoveryRequired,
    NtfsSparseMetadata,
    NtfsUnsupportedVersion,
    NtfsWriteDenied,
};

pub const Btrfs = error{
    BtrfsAmbiguousSuper,
    BtrfsBlockGroupAccounting,
    BtrfsChecksum,
    BtrfsDeviceAccounting,
    BtrfsDeviceExtent,
    BtrfsDeviceMismatch,
    BtrfsDroppingRootUnsupported,
    BtrfsDuplicateRoot,
    BtrfsExtentAccounting,
    BtrfsInvalidChunk,
    BtrfsInvalidCreateSize,
    BtrfsInvalidInode,
    BtrfsInvalidNode,
    BtrfsInvalidResizeDirection,
    BtrfsInvalidResizeSize,
    BtrfsInvalidRoot,
    BtrfsInvalidSuper,
    BtrfsKeyOrder,
    BtrfsMissingTree,
    BtrfsOverlappingChunks,
    BtrfsParentMismatch,
    BtrfsRecoveryRequired,
    BtrfsReplicaMismatch,
    BtrfsSystemChunkMismatch,
    BtrfsTreeCycle,
    BtrfsUnallocatedNode,
    BtrfsUnmappedAddress,
    BtrfsUnsupportedChecksum,
    BtrfsUnsupportedFeatures,
    BtrfsUnsupportedProfile,
    BtrfsUnsupportedSectorSize,
    BtrfsWrongSize,
};

test "only explicitly classified failures become inconsistent check results" {
    try std.testing.expect(contains(Fat, error.FatBrokenChain));
    try std.testing.expect(contains(Ntfs, error.NtfsBitmapMismatch));
    try std.testing.expect(contains(Btrfs, error.BtrfsChecksum));
    inline for (.{ Fat, Ntfs, Btrfs }) |Errors| {
        try std.testing.expect(!contains(Errors, error.OutOfMemory));
        try std.testing.expect(!contains(Errors, error.InputOutput));
        try std.testing.expect(!contains(Errors, error.FatResourceLimit));
        try std.testing.expect(!contains(Errors, error.NtfsResourceLimit));
        try std.testing.expect(!contains(Errors, error.BtrfsResourceLimit));
        try std.testing.expect(!contains(Errors, error.FatUnclassifiedFailure));
        try std.testing.expect(!contains(Errors, error.NtfsUnclassifiedFailure));
        try std.testing.expect(!contains(Errors, error.BtrfsUnclassifiedFailure));
    }
}
