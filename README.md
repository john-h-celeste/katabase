# katabase
RAG app built using Docker and mostly off the shelf tools

# setup, run, and test
setup
```
mkdir data data/models data/db
curl -L -o data/models/qwen2.5-0.5b-instruct-fp16.gguf https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-fp16.gguf
```
run
```
docker compose -f yamltest.yml up
```
test
```
docker exec -t rag-inference curl http://localhost:8080/v1/chat/completions -H "Content-Type: application/json"     -d '{"messages": [{"role": "system", "content": "You are a helpful assistant."}, {"role": "user", "content": "Write a limerick about python exceptions"}]}'
```
