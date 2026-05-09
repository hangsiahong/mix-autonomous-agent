# AMA Multi-modal Support

AMA now supports multi-modal inputs, primarily focusing on Image Vision via Telegram.

## Features
- **Image Vision**: AMA can process photos and image documents sent via Telegram. 
- **Automatic Conversion**: Images are automatically downloaded, converted to base64, and sent to the LLM.
- **Multi-modal History**: Conversation history now supports complex content arrays (text + images).
- **Proactive Recognition**: System prompt updated to inform AMA it has vision capabilities.

## Implementation Details
- `core/telegram/media.sh`: Handles extraction of media from Telegram updates.
- `core/mix/11_history.sh`: `append_text` updated to support JSON content arrays.
- `core/mix/24_agent_loop.sh`: Agent loop now accepts and passes media context.

## Planned
- **Audio Support**: Integrating Google Gemini File API for voice message processing.
- **Video Support**: Frame extraction or File API integration.
- **PDF/Document Parsing**: Extracting text from uploaded documents.
