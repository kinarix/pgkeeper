// SPDX-License-Identifier: Apache-2.0

package instance

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Install copies each source file into dir, keeping its base name, and
// verifies the copy's SHA-256 against the source. It is the init-copy
// delivery path of the tools image, which has no shell (02 §2). Each file is
// written to a temporary name and renamed, so dir never holds a partial file.
func Install(dir string, sources ...string) error {
	st, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("checking install dir: %w", err)
	}
	if !st.IsDir() {
		return fmt.Errorf("install dir %s: %w", dir, ErrNotDirectory)
	}
	for _, src := range sources {
		if err := installFile(src, filepath.Join(dir, filepath.Base(src))); err != nil {
			return err
		}
	}
	return nil
}

func installFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("opening %s: %w", src, err)
	}
	defer func() { _ = in.Close() }()

	tmp, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".*")
	if err != nil {
		return fmt.Errorf("creating temp file for %s: %w", dst, err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }()

	srcSum := sha256.New()
	if _, err := io.Copy(tmp, io.TeeReader(in, srcSum)); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("copying %s: %w", src, err)
	}
	if err := tmp.Chmod(0o555); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("setting mode on %s: %w", dst, err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("syncing %s: %w", dst, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing %s: %w", dst, err)
	}

	dstSum, err := fileSHA256(tmp.Name())
	if err != nil {
		return err
	}
	if !bytes.Equal(srcSum.Sum(nil), dstSum) {
		return fmt.Errorf("copy of %s: %w", src, ErrChecksumMismatch)
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		return fmt.Errorf("installing %s: %w", dst, err)
	}
	return nil
}

func fileSHA256(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, fmt.Errorf("hashing %s: %w", path, err)
	}
	return h.Sum(nil), nil
}
