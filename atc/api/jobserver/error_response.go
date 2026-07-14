package jobserver

import (
	"encoding/json"
	"net/http"
)

// writeJSONError writes a {"error": "..."} envelope with the given status,
// matching the Content-Type: application/json header the job endpoints set.
func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}
