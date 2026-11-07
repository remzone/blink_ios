package resources

import (
	"crypto/sha256"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestAssetsStreamingIntegrityAndBoundedAllocations(t *testing.T) {
	dir := t.TempDir()
	if e := Prepare(dir); e != nil {
		t.Fatal(e)
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		a, e := data.Open(name)
		if e != nil {
			t.Fatal(e)
		}
		expected := sha256.New()
		io.Copy(expected, a)
		a.Close()
		b, e := os.Open(filepath.Join(dir, name))
		if e != nil {
			t.Fatal(e)
		}
		actual := sha256.New()
		io.Copy(actual, b)
		b.Close()
		if string(expected.Sum(nil)) != string(actual.Sum(nil)) {
			t.Fatal("asset mismatch")
		}
	}
	result := testing.Benchmark(func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			if e := Prepare(dir); e != nil {
				b.Fatal(e)
			}
		}
	})
	if result.AllocedBytesPerOp() > 1024*1024 {
		t.Fatalf("asset verification allocated %d bytes; avoid whole-file copies", result.AllocedBytesPerOp())
	}
	if e := os.WriteFile(filepath.Join(dir, "geoip.dat"), []byte("corrupt"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := Prepare(dir); e != nil {
		t.Fatal(e)
	}
	f, e := os.Stat(filepath.Join(dir, "geoip.dat"))
	if e != nil || f.Size() < 1024 {
		t.Fatal("corrupt asset not replaced")
	}
}
