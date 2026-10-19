// SPDX-License-Identifier: Apache-2.0

// Package instance implements the instance manager (02-instance-manager).
package instance

import "errors"

var (
	// ErrNotDirectory is returned when an install target is not a directory.
	ErrNotDirectory = errors.New("not a directory")
	// ErrChecksumMismatch is returned when a copied file differs from its source.
	ErrChecksumMismatch = errors.New("checksum mismatch")
)
