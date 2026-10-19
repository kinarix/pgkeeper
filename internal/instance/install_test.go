// SPDX-License-Identifier: Apache-2.0

package instance

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestInstall(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		setup   func(t *testing.T, srcDir, dstDir string) (dir string, sources []string)
		wantErr error // nil: success; fs.ErrNotExist etc. matched with errors.Is
	}{
		{
			name: "copies every source",
			setup: func(t *testing.T, srcDir, dstDir string) (string, []string) {
				a, b := filepath.Join(srcDir, "pgkeeper-instance"), filepath.Join(srcDir, "wal-g")
				writeFile(t, a, []byte("instance binary"))
				writeFile(t, b, bytes.Repeat([]byte("wal-g"), 1<<16))
				return dstDir, []string{a, b}
			},
		},
		{
			name: "overwrites an existing copy",
			setup: func(t *testing.T, srcDir, dstDir string) (string, []string) {
				a := filepath.Join(srcDir, "wal-g")
				writeFile(t, a, []byte("new"))
				writeFile(t, filepath.Join(dstDir, "wal-g"), []byte("old and longer"))
				return dstDir, []string{a}
			},
		},
		{
			name: "missing source",
			setup: func(_ *testing.T, srcDir, dstDir string) (string, []string) {
				return dstDir, []string{filepath.Join(srcDir, "wal-g")}
			},
			wantErr: fs.ErrNotExist,
		},
		{
			name: "missing install dir",
			setup: func(t *testing.T, srcDir, dstDir string) (string, []string) {
				a := filepath.Join(srcDir, "wal-g")
				writeFile(t, a, []byte("x"))
				return filepath.Join(dstDir, "absent"), []string{a}
			},
			wantErr: fs.ErrNotExist,
		},
		{
			name: "install dir is a file",
			setup: func(t *testing.T, srcDir, dstDir string) (string, []string) {
				a := filepath.Join(srcDir, "wal-g")
				writeFile(t, a, []byte("x"))
				f := filepath.Join(dstDir, "file")
				writeFile(t, f, nil)
				return f, []string{a}
			},
			wantErr: ErrNotDirectory,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srcDir, dstDir := t.TempDir(), t.TempDir()
			dir, sources := tt.setup(t, srcDir, dstDir)

			err := Install(dir, sources...)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("Install() error = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Install() error = %v", err)
			}
			for _, src := range sources {
				dst := filepath.Join(dir, filepath.Base(src))
				want, _ := os.ReadFile(src)
				got, err := os.ReadFile(dst)
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(got, want) {
					t.Errorf("%s content differs from source", dst)
				}
				st, _ := os.Stat(dst)
				if st.Mode().Perm() != 0o555 {
					t.Errorf("%s mode = %v, want 0555", dst, st.Mode().Perm())
				}
			}
			entries, _ := os.ReadDir(dir)
			if len(entries) != len(sources) {
				t.Errorf("install dir has %d entries, want %d (temp files left behind?)", len(entries), len(sources))
			}
		})
	}
}
