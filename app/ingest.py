print("App starting")

import os
import time

import psycopg
import pgvector
import pgvector.psycopg

import openai

start_time = time.time()
def tprint(*args, **kwargs):
	print(f"[{time.time() - start_time:.6}] ", *args, **kwargs)

tprint("Imported libraries")

MODEL = 'qwen2.5-0.5b-instruct-fp16'

DOCS_DIR = '/docs'

client = openai.OpenAI(base_url = 'http://inference:8080/v1', api_key = '-')
conn = psycopg.connect(host = 'db', dbname = 'ragdb', user = 'raguser', password = '<<password>>')

tprint('Connected to database')

conn.execute('CREATE EXTENSION IF NOT EXISTS vector')
pgvector.psycopg.register_vector(conn)

cur = conn.cursor()
cur.execute('SELECT table_name, * FROM information_schema.tables where table_schema <> %s', ('information_schema',))
print([*cur])

cur.execute('SELECT exists(SELECT table_name from information_schema.tables WHERE table_name = %s)', ('knowledge',))
has_knowledge = cur.fetchone()[0]

def make_chunks(text, chunk_size, overlap):
	chunks = []
	while len(text) > 0:
		chunks.append(text[:chunk_size])
		text = text[chunk_size - overlap:]
	return chunks

time.sleep(1)

if has_knowledge:
	tprint("Knowledge table exists")
else:
	tprint("Knowledge table does not exist, creating it...")

	texts = []
	files = os.listdir(DOCS_DIR)
	for name in files:
		with open(os.path.join(DOCS_DIR, name)) as f:
		 	texts.append(f.read())

	chunks = [chunk for text in texts for chunk in make_chunks(text, chunk_size = 1000, overlap = 300)]

	embeddings = [pgvector.Vector(e.embedding) for e in client.embeddings.create(
		model = MODEL,
		input = chunks,
	).data]
	embedding_size = embeddings[0].dimensions()

	tprint("{len(embeddings)} embeddings generated for {len(chunks)} chunks ({len(files} documents)")

	# make sure the table exists with the correct type
	conn.execute('''DROP TABLE IF EXISTS knowledge''')
	conn.execute(psycopg.sql.SQL('''
		CREATE TABLE knowledge (
			id bigserial PRIMARY KEY,
			content text,
			embedding vector({embedding_size})
		)
	''').format(embedding_size = embedding_size))

	with cur.copy('COPY knowledge (content, embedding) FROM STDIN WITH (FORMAT BINARY)') as copy:
		copy.set_types(['text', 'vector'])

		for content,embedding in zip(chunks, embeddings):
			copy.write_row([content, embedding])

	conn.commit()

	tprint("Knowledge table created")

query = 'What truths are held to be self-evident?'

embedding = client.embeddings.create(
	model = MODEL,
	input = query,
).data[0].embedding

result = conn.execute('SELECT content FROM knowledge ORDER BY embedding <=> %s LIMIT 5', (pgvector.Vector(embedding),)).fetchall()
tprint(result)
context = '\n\n'.join([row[0] for row in result])

response = client.chat.completions.create(
    model = MODEL,  # Can be any string, or the model alias if configured
    messages = [
        {'role': 'system', 'content': "You are a helpful assistant."},
        {'role': 'user', 'content': query},
        {'role': 'user', 'content': context},
    ],
    temperature = 0.7
)

tprint(response)
