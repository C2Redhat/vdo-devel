##
# Provide a basic framework for migrating from one machine to another,
# in order to test changes to hardware, platform, or VDO version.
#
# $Id$
##
package VDOTest::MigrationBase;

use strict;
use warnings FATAL => qw(all);
use English qw(-no_match_vars);
use Log::Log4perl;

use Permabit::Assertions qw(
  assertEqualNumeric
  assertGTNumeric
  assertLTNumeric
  assertNumArgs
);
use Permabit::Constants;
use Permabit::Utils qw(ceilMultiple);

use base qw(VDOTest);

my $log = Log::Log4perl->get_logger(__PACKAGE__);

#############################################################################
# @paramList{getProperties}
our %PROPERTIES =
  (
   # @ple Audit VDO metadata
   auditVDO           => 1,
   # @ple Number of blocks to write
   blockCount         => 33000,
   # @ple Use an upgrade device backed by iscsi, and don't use stripfua
   deviceType         => "upgrade-iscsi-linear",
   # @ple VDO Stats to compare after upgrade
   _preMigrationStats => undef,
   # @ple Data to share between test methods
   _testData          => undef,
  );
##

#############################################################################
##
sub establishStartingDevice {
  my ($self) = assertNumArgs(1, @_);

  my $device = $self->getDevice();
  my $dataSize = $self->{blockCount} * $self->{blockSize};

  my $initStats = $device->getVDOStats();
  assertEqualNumeric(0, $initStats->{"data blocks used"},
                     "Starting data blocks used should be zero");
  assertEqualNumeric(0, $initStats->{"logical blocks used"},
                     "Starting logical block used should be zero");

  $self->{_testdata}
    = [
       $self->createSlice(
                          blockCount => $self->{blockCount},
                         ),
       $self->createSlice(
                          blockCount => $self->{blockCount} / 2,
                          offset     => $self->{blockCount},
                         ),
       $self->createSlice(
                          blockCount => $self->{blockCount} / 2,
                          offset     => $self->{blockCount} * 3 / 2,
                         ),
      ];
  $self->{_testdata}[0]->write(tag => "data", fsync => 1);
  # Write half the blocks again, expecting complete dedupe.
  $self->{_testdata}[1]->write(tag => "data", fsync => 1);

  # If we have dedupe enabled, make sure we get exactly the dedupe we want.
  my $preCompressStats = $device->getVDOStats();
  if (!$self->{disableAlbireo}) {
    assertEqualNumeric($self->{blockCount},
                       $preCompressStats->{"data blocks used"},
                       "Data blocks used should be block count");
  }

  # Write some compressible blocks
  my $compression = $device->isVDOCompressionEnabled();
  $device->enableCompression();
  $self->{_testdata}[2]->write(tag => "data2", fsync => 1, compress => .9);
  # Restore old compression status; then make sure compression happened.
  if (!$compression) {
    $device->disableCompression();
  }
  $self->{_preMigrationStats} = $device->getVDOStats();
  assertGTNumeric($self->{_preMigrationStats}->{"compressed blocks written"}, 0,
                  "There are some compressed blocks");
  assertGTNumeric($self->{_preMigrationStats}->{"compressed fragments written"},
                  0, "There are some compressed fragments");
  # With 90% compressible data, we should at least save 80% of the space.
  my $dataBlocksUsed = ($self->{_preMigrationStats}->{"data blocks used"}
                        - $preCompressStats->{"data blocks used"});
  assertLTNumeric($dataBlocksUsed, $self->{blockCount} / 5,
                  "Block writes should be compressed");

  # Don't check dedupe stats if we aren't running with deduplication.
  if (!$self->{disableAlbireo}) {
    assertEqualNumeric(0, $self->{_preMigrationStats}->{"dedupe advice timeouts"},
                       "Dedupe advice timeouts should be zero");
    assertEqualNumeric(($self->{blockCount} / 2),
                       $self->{_preMigrationStats}->{"dedupe advice valid"},
                       "Dedupe advice valid should be half the block count");
    assertEqualNumeric(0, $self->{_preMigrationStats}->{"dedupe advice stale"},
                       "Dedupe advice stale should be zero");
  }
}

#############################################################################
# Test basic read/write and dedupe capability after an upgrade.
##
sub verifyFinalState {
  my ($self) = assertNumArgs(1, @_);

  my $device = $self->getDevice();
  my $postMigrationStats = $device->getVDOStats();
  my @unchangedStats = (
                         "data blocks used",
                         "logical blocks used",
                         "logical blocks",
                         "physical blocks",
                        );
  foreach my $field (@unchangedStats) {
    assertEqualNumeric($self->{_preMigrationStats}->{$field},
                       $postMigrationStats->{$field},
                       "Stats for $field should be the same");
  }

  # Verify all the data have not changed.
  $self->{_testdata}[0]->verify();
  $self->{_testdata}[1]->verify();
  $self->{_testdata}[2]->verify();

  # Overwrite the second half with the first half of data blocks.
  # Data should dedupe and free up half the blocks.
  my $blocksWritten = $self->{blockCount} / 2;
  my $overwriteSlice
    = $self->createSlice(
                         blockCount => $blocksWritten,
                         offset     => $self->{blockCount} / 2,
                        );
  $overwriteSlice->write(tag => "data", fsync => 1);

  my $overwriteDedupeStats = $device->getVDOStats();
  assertEqualNumeric(0, $overwriteDedupeStats->{"dedupe advice timeouts"},
                     "Dedupe advice timeouts should be zero");
  assertEqualNumeric($blocksWritten,
                     $overwriteDedupeStats->{"dedupe advice valid"},
                     "Dedupe advice valid should be block count");
  assertEqualNumeric(0, $overwriteDedupeStats->{"dedupe advice stale"},
                     "Dedupe advice stale should be zero");
  assertEqualNumeric(($self->{_preMigrationStats}->{"data blocks used"}
                      - $blocksWritten),
                     $overwriteDedupeStats->{"data blocks used"},
                     "Each overwritten block freed a used block");

  # Reboot then continue to use the new VDO.
  $self->rebootMachineForDevice($device);
  $device->verifyModuleVersion();

  # Grow the VDO volume by an arbitrary 60%, then read.
  my $newPhysicalSize = int($self->{physicalSize} * 8 / 5);
  $device->growPhysical($newPhysicalSize);
  $overwriteSlice->verify();

  # Enable compression and write compressible data.
  $device->enableCompression();

  my $compressSlice
    = $self->createSlice(
                         blockCount => $self->{blockCount},
                         offset     => $self->{blockCount} * 3,
                        );
  $compressSlice->write(tag => "data", fsync => 1, compress => .9);
  $compressSlice->verify();

  my $compressionStats = $device->getVDOStats();
  # With 90% compressible data, we should at least save 80% of the space.
  my $dataBlocksUsed = ($compressionStats->{"data blocks used"}
                        - $overwriteDedupeStats->{"data blocks used"});
  assertLTNumeric($dataBlocksUsed, $self->{blockCount} / 5,
                  "Block writes should be compressed");
  assertGTNumeric($compressionStats->{"compressed blocks written"}, 0,
                  "There are some compressed blocks");
  assertGTNumeric($compressionStats->{"compressed fragments written"}, 0,
                  "There are some compressed fragments");

  # Grow logical by an arbitrary 60%, then use it.
  my $offTheEndSlice
    = $self->createSlice(
                         blockCount => $self->{blockCount},
                         offset     => $self->{logicalSize} / $KB / 4,
                        );

  my $newLogicalBytes = ceilMultiple(int($self->{logicalSize} * 8 / 5),
                                     $DEFAULT_BLOCK_SIZE);
  $device->growLogical($newLogicalBytes);
  $offTheEndSlice->write(tag => "end", fsync => 1);
  $offTheEndSlice->verify();
}

#############################################################################
# Move the VDO device to a new scenario.
##
sub switchToIntermediateScenario {
  my ($self, $scenario) = assertNumArgs(2, @_);
  my $device = $self->getDevice();
  $device->stop();
  $device->switchToScenario($scenario);
  $device->start();
}

1;