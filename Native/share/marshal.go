package share

import (
	"bytes"
	"encoding/json"
	"github.com/xtls/xray-core/infra/conf"
)

// MarshalOutbound preserves raw settings and omits absent REALITY server fields.
// Xray distinguishes a missing target/dest from an explicit JSON null: null
// selects server configuration on the second parse and rejects a client profile.
func MarshalOutbound(out *conf.OutboundDetourConfig) (json.RawMessage, error) {
	raw, err := json.Marshal(out)
	if err != nil {
		return nil, err
	}
	var outbound map[string]json.RawMessage
	if err = json.Unmarshal(raw, &outbound); err != nil {
		return nil, err
	}
	var stream map[string]json.RawMessage
	if err = json.Unmarshal(outbound["streamSettings"], &stream); err != nil || stream == nil {
		return raw, nil
	}
	var reality map[string]json.RawMessage
	if err = json.Unmarshal(stream["realitySettings"], &reality); err != nil || reality == nil {
		return raw, nil
	}
	for _, key := range []string{"target", "dest"} {
		if bytes.Equal(bytes.TrimSpace(reality[key]), []byte("null")) {
			delete(reality, key)
		}
	}
	stream["realitySettings"], err = json.Marshal(reality)
	if err != nil {
		return nil, err
	}
	outbound["streamSettings"], err = json.Marshal(stream)
	if err != nil {
		return nil, err
	}
	return json.Marshal(outbound)
}
