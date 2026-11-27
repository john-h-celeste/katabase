import psycopg
import openai
import pgvector

MODEL = 'qwen2.5-0.5b-instruct-fp16'

DOCS_DIR = '/docs'

client = openai.OpenAI(base_url = 'http://inference:8080/v1', api_key = '')
conn = psycopg.connect(host = '', dbname = 'ragdb', user = 'raguser', password = '<<password>>')

conn.execute('CREATE EXTENSION IF NOT EXISTS vector')
pgvector.psycopg.register_vector(conn)

cur = conn.cursor()
cur.execute('SELECT exists(SELECT * FROM information_schema.tables WHERE table_name=%s)', ('knowledge',))
has_knowledge = cur.fetchone()[0]

def make_chunks(text, chunk_size, overlap):
	chunks = []
	while len(text) > 0:
		chunks.append(text[:chunk_size])
		text = text[chunk_size - overlap:]
	return chunks

if has_knowledge:
	print("Knowledge table exists")
else:
	print("Knowledge table does not exist, creating it...")

	# make sure the table exists with the correct type
	conn.execute('''DROP TABLE IF EXISTS knowledge''')
	conn.execute('''
		CREATE TABLE knowledge (
			id bigserial PRIMARY KEY,
			content text,
			embedding vector(768)
		)
	''')

	files = os.listdir(DOCS_DIR)
	for name in files:
		with open(os.path.join(DOCS_DIR, name)) as f:
		 	texts.append(f.read())

	chunks = [chunk for text in texts for chunk in make_chunks(text, chunk_size = 1000, overlap = 100)]

	embeddings = [pgvector.Vector(e.embedding) for e in client.embeddings.create(
		model = MODEL,
		input = chunks,
	).data]

	with cur.copy('COPY knowledge (content, embedding) FROM STDIN WITH (FORMAT BINARY)') as copy:
		copy.set_types(['text', 'vector'])

		for content,embedding in zip(chunks, embeddings):
			copy.write_row([content, embedding])

	print("Knowledge table created")

result = conn.execute('SELECT content FROM knowledge ORDER BY embedding <=> %s LIMIT 5', (Vector(embedding),)).fetchall()
context = '\n\n'.join([row[0] for row in result])

response = client.chat.completions.create(
    model = MODEL,  # Can be any string, or the model alias if configured
    messages = [
        {'role': 'system', 'content': "You are a helpful coding assistant."},
        {'role': 'user', 'content': "Write a Python function to reverse a string."}
        {'role': 'user', 'content': context}
    ],
    temperature = 0.7
)

print(response)