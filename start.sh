#!/bin/bash

set -e

# Clean exit on Ctrl+C
trap ctrl_c INT

ctrl_c() {
  echo "🛑 Caught Ctrl+C. Stopping QLever server..."
  if [[ -n "$QLEVER_PID" ]]; then
    kill "$QLEVER_PID" 2>/dev/null || true
  fi
  echo "👋 Exiting."
  exit 0
}

# ----- Configuration -----
QLEVER_DIR="$(pwd)/qlever"
CONTROL_DIR="$(pwd)/qlever-control"
DATA_DIR="$(pwd)/data"
INDEX_DIR="$DATA_DIR/minimal-index"
TTL_FILE="$DATA_DIR/minimal.ttl"
INDEX_BASENAME="$INDEX_DIR/index"
SERVER_BIN="$QLEVER_DIR/build/ServerMain"
INDEX_BUILDER_BIN="$QLEVER_DIR/build/IndexBuilderMain"
LOG_FILE="$(pwd)/qlever.log"
PORT=7000
QUERY_URL="http://localhost:$PORT/query?query=SELECT%20?s%20WHERE%20%7B%20?s%20?p%20?o%20%7D%20LIMIT%201"

# ----- Setup -----
echo "📁 Ensuring qlever-control is cloned..."
if [ ! -d "$CONTROL_DIR" ]; then
  git clone https://github.com/ad-freiburg/qlever-control.git "$CONTROL_DIR"
else
  echo "✅ qlever-control already exists"
fi

echo "📁 Creating data directory..."
mkdir -p "$DATA_DIR"

echo "📄 Creating RDF Turtle dataset..."
cat <<EOF > "$TTL_FILE"
@prefix ex: <http://example.org/> .
@prefix foaf: <http://xmlns.com/foaf/0.1/> .
ex:alice a foaf:Person ;
         foaf:name "Alice" ;
         foaf:knows ex:bob .
ex:bob a foaf:Person ;
       foaf:name "Bob" ;
       foaf:knows ex:charlie .
ex:charlie a foaf:Person ;
           foaf:name "Charlie" .
EOF

# ----- Build Index -----
echo "🔨 Building QLever index..."
rm -rf "$INDEX_DIR"
mkdir -p "$INDEX_DIR"

"$INDEX_BUILDER_BIN" \
  --index-basename "$INDEX_BASENAME" \
  --kg-input-file "$TTL_FILE" \
  --file-format ttl \
  --parse-parallel false

# ----- Verify Index -----
echo "🧪 Verifying index files..."
if ! ls "$INDEX_BASENAME".* >/dev/null 2>&1; then
  echo "❌ Index build failed: no output files at $INDEX_BASENAME.*"
  exit 1
fi

# ----- Start Server -----
echo "🔍 Checking for existing QLever server on port $PORT..."
if lsof -i:$PORT &>/dev/null; then
  echo "🛑 Killing existing QLever process..."
  pkill -f "$SERVER_BIN" || true
  sleep 2
fi

echo "🚀 Starting QLever server on port $PORT..."
nohup "$SERVER_BIN" \
  --index-basename "$INDEX_BASENAME" \
  --port "$PORT" \
  > "$LOG_FILE" 2>&1 &
QLEVER_PID=$!
sleep 2

if ! kill -0 "$QLEVER_PID" 2>/dev/null; then
  echo "❌ QLever server failed to start."
  echo "📜 Log output:"
  cat "$LOG_FILE"
  exit 1
fi
echo "✅ QLever server running (PID $QLEVER_PID)"

# ----- Test the QLever API -----
echo "🔍 Verifying QLever API response..."
RESPONSE=$(curl -s "$QUERY_URL")

if [[ "$RESPONSE" == *"results"* && "$RESPONSE" == *"bindings"* ]]; then
  echo "✅ QLever responded successfully to test query."
  echo ""
  echo "📤 Expected structure (JSON):"
  echo '{'
  echo '  "head": { "vars": ["s"] },'
  echo '  "results": {'
  echo '    "bindings": ['
  echo '      { "s": { "type": "uri", "value": "http://example.org/alice" } }'
  echo '    ]'
  echo '  }'
  echo '}'
else
  echo "❌ Query failed. Server log:"
  cat "$LOG_FILE"
  kill "$QLEVER_PID" 2>/dev/null || true
  exit 1
fi

# ----- Confirm qlever-control uses local QLever -----
CONTROL_QUERY_SCRIPT="$CONTROL_DIR/qlever-query.sh"

if grep -q "http://localhost:$PORT" "$CONTROL_QUERY_SCRIPT"; then
  echo "✅ qlever-control is configured to use your local QLever server at http://localhost:$PORT/query"
else
  echo "⚠️  WARNING: qlever-control may be using the public QLever instance."
  echo "   Please check the file:"
  echo "     $CONTROL_QUERY_SCRIPT"
  echo "   And make sure it contains:"
  echo "     http://localhost:$PORT/query"
fi

# ----- Instructions -----
echo ""
echo "🌐 You can now test in your browser:"
echo "   $QUERY_URL"
echo ""
echo "🧪 Or use curl:"
echo "   curl '$QUERY_URL'"
echo ""
echo "⌛ Waiting... Press Ctrl+C to stop the QLever server."

# ----- Wait for Ctrl+C -----
wait
