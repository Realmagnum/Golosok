# План реализации архитектурного решения (Уровень 1: Contextual Biasing & Hotwords)

## Этап 1. Исследование и валидация CLI-рантайма
1. **Анализ текущего `transcribe-cli`:**
   * Проверить сборку `transcribe-cli` в бандле `Golosok-Dev.app` / `Resources`.
   * Определить поддержку аргументов контекстного смещения или n-gram LM для GGUF RNN-T.
   * *Примечание:* Для whisper доступен `--initial-prompt`. Для RNN-T GGUF прямой флаг hotwords отсутствует.
2. **Оценка интеграции `sherpa-onnx` для GigaAM v3:**
   * Проверить веса `csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian` (ONNX export).
   * Оценить бинарник `sherpa-onnx-offline` на macOS (Apple Silicon Metal / CPU NEON): скорость инференса, поддержка `--hotwords-file` и `--hotwords-score`.
   * Измерить разницу в потреблении памяти: текущий GGUF Q8_0 (~100 МБ) vs ONNX INT8/FP16.

## Этап 2. Прототипирование Hotwords с графом Aho-Corasick
1. **Подготовка тестового аудио-сета:**
   * Сформировать 10–15 WAV-файлов из реальной папки `~/Library/Application Support/Golosok/Audio/`, содержащих термины:
     * *Tailscale*, *Hindsight*, *OpenCode*, *Vaultwarden*, *LLDP/SNMP*, *Ollama*.
2. **Генерация hotwords-словаря:**
   * Преобразование списка канонических слов в BPE-токены словаря GigaAM.
   * Тестирование параметров:
     * `hotwords-score` от 1.0 до 5.0 (поиск порога без ложных срабатываний).
3. **Бенчмаркинг точности:**
   * Сравнить WER / Keyword Error Rate (KER) на тестовом наборе:
     * Базовый GigaAM RNN-T (без смещения).
     * GigaAM RNN-T + Hotwords Aho-Corasick.
     * Базовый + Rule-based Replacer.

## Этап 3. Исследование Shallow Fusion с легковесной KenLM
1. **Сборка текстового корпуса IT-терминологии:**
   * Дампы названий CLI-утилит (man-страницы, brew formulas, документация).
2. **Обучение 3-gram / 4-gram языковой модели через KenLM:**
   * Сжатие в бинарный формат `.arpa` / `.binary` (< 20–30 МБ).
3. **Оценка вычислительной целесообразности:**
   * Измерение просадки FPS / RTF при Beam Search против Greedy Search.

## Этап 4. Интеграция в Swift-код «Голоска»
1. Модификация `AudioCapture.swift`:
   * Передача файла горячих слов при вызове CLI.
   * Обработка токенов и таймстемпов.
2. Добавление защитного слоя (Fallback):
   * Если CLI не поддерживает hotwords для конкретной модели, управление прозрачно передается на Уровень 2 (TermReplacer).
