from pydantic import BaseModel

class UploadResponse(BaseModel):
    ok: bool
    path: str