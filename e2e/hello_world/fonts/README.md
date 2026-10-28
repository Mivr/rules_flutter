These two fonts are generated fixtures, not third-party files. Each is a
minimal sfnt file: a valid offset table plus one `head` table, with the magic
`00 01 00 00` and a correctly computed table checksum and
`checkSumAdjustment`. They carry no glyphs and have no license obligations.
Their bytes differ (`fontRevision`), so a test that reads the wrong file can
tell.
