# -*- coding: utf-8 -*-
#
#  main.py
#  day25-fastapi-agent
#
#  Created by 宋时成 on 2026/06/04.
#
#  Day 25 实战：FastAPI 后端集成 SSE 学习计划生成 Agent
#  - 兼容 Day 23 的 /health, /upload, /stream_query 接口
#  - 新增 /stream_agent 接口 ➔ 采用原生 StreamingResponse 流式泵送智能体推理状态
#  - 状态帧设计：
#    - {"type": "thought", "content": "..."} ➔ 推送大脑思考过程
#    - {"type": "action", "name": "...", "input": "..."} ➔ 提示客户端正在调用本地物理工具
#    - {"type": "observation", "content": "..."} ➔ 提示客户端本地工具执行完成并返回观测
#    - {"type": "content", "delta": "..."} ➔ 打字机流式推送最终生成的学习计划
#  - 内置 search_web (联网搜索) 与 calculator (安全计算器) 两大物理工具，大模型采用 OpenAI Stop Sequence 阻断幻觉
#

import os
import sys
import io
import math
import json
import re
import asyncio
import logging
from typing import List, Dict, Any, Tuple
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn
import chromadb
from pypdf import PdfReader
from dotenv import load_dotenv
from openai import OpenAI
from duckduckgo_search import DDGS
from langchain_text_splitters import RecursiveCharacterTextSplitter

# ==========================================
# 1. 初始化日志与环境配置 📐
# ==========================================
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("FastAPI-Agent")

current_dir = os.path.dirname(os.path.abspath(__file__))
env_path = os.path.join(current_dir, ".env")

if os.path.exists(env_path):
    load_dotenv(env_path, override=True)
else:
    load_dotenv(override=True)

DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY")
SILICONFLOW_API_KEY = os.getenv("SILICONFLOW_API_KEY")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
ZHIPU_API_KEY = os.getenv("ZHIPU_API_KEY")

# ==========================================
# 2. 持久化向量数据库配置 📂
# ==========================================
DB_PATH = os.path.join(current_dir, "chroma_data")
chroma_client = chromadb.PersistentClient(path=DB_PATH)
COLLECTION_NAME = "study_assistant"


def get_embeddings(texts: List[str]) -> List[List[float]]:
    """获取向量特征，支持在线 API 与离线哈希仿真"""
    global OPENAI_API_KEY, ZHIPU_API_KEY, SILICONFLOW_API_KEY, DEEPSEEK_API_KEY
    has_key = any(
        k and k.startswith("sk-") or (k and k.startswith("zhipu-")) 
        for k in [OPENAI_API_KEY, ZHIPU_API_KEY, SILICONFLOW_API_KEY, DEEPSEEK_API_KEY]
    )
    
    if not has_key:
        dimension = 1536
        results = []
        for text in texts:
            vec = [0.0] * dimension
            words = list(text.lower())
            for i in range(len(text) - 1):
                words.append(text[i:i+2].lower())
            for word in words:
                h = 0
                for char in word:
                    h = (31 * h + ord(char)) % dimension
                vec[h] += 1.0
            mag = math.sqrt(sum(x ** 2 for x in vec))
            if mag > 0:
                vec = [x / mag for x in vec]
            else:
                vec = [1.0 / math.sqrt(dimension)] * dimension
            results.append(vec)
        return results

    try:
        if ZHIPU_API_KEY:
            client = OpenAI(api_key=ZHIPU_API_KEY, base_url="https://open.bigmodel.cn/api/paas/v4")
            model_name = "embedding-2"
        elif SILICONFLOW_API_KEY:
            client = OpenAI(api_key=SILICONFLOW_API_KEY, base_url="https://api.siliconflow.cn/v1")
            model_name = "BAAI/bge-large-zh-v1.5"
        else:
            client = OpenAI(api_key=OPENAI_API_KEY)
            model_name = "text-embedding-3-small"
            
        batch_size = 16
        embeddings = []
        for i in range(0, len(texts), batch_size):
            batch = texts[i:i + batch_size]
            response = client.embeddings.create(input=batch, model=model_name)
            embeddings.extend([item.embedding for item in response.data])
        return embeddings
    except Exception as e:
        logger.warning(f"向量化 API 异常 ({e})，平滑切换至本地离线仿真...")
        OPENAI_API_KEY = ZHIPU_API_KEY = SILICONFLOW_API_KEY = None
        return get_embeddings(texts)


def get_llm_client_and_model():
    """获取可用的大模型客户端与模型名称，支持官方 DeepSeek 与 硅基流动 双通道灾备"""
    global DEEPSEEK_API_KEY, SILICONFLOW_API_KEY
    
    if DEEPSEEK_API_KEY:
        client = OpenAI(api_key=DEEPSEEK_API_KEY, base_url="https://api.deepseek.com")
        model_name = "deepseek-chat"
        provider = "DeepSeek Official"
    elif SILICONFLOW_API_KEY:
        client = OpenAI(api_key=SILICONFLOW_API_KEY, base_url="https://api.siliconflow.cn/v1")
        model_name = "deepseek-ai/DeepSeek-V3"
        provider = "SiliconFlow"
    else:
        client = None
        model_name = "fallback-offline"
        provider = "Offline Simulation"
        
    return client, model_name, provider


# ==========================================
# 3. 定义 Agent 物理工具 🛠️
# ==========================================
def search_web(query: str) -> str:
    """工具 1：联网检索最新的热点事件、技术发展、学习大纲等"""
    logger.info(f"   [Agent Tool] 🔍 正在网络检索: \"{query}\" ...")
    try:
        results_summary = []
        with DDGS() as ddgs:
            ddgs_generator = ddgs.text(query, max_results=3)
            for idx, r in enumerate(ddgs_generator, 1):
                title = r.get("title", "无标题")
                body = r.get("body", "无内容摘要")
                results_summary.append(f"结果 {idx}: 【{title}】\n摘要: {body}")
        
        if not results_summary:
            return "【联网检索反馈】搜索完成，但没有找到相关的网页结果。"
        return "\n\n".join(results_summary)
    except Exception as err:
        return f"【联网检索失败】在执行联网搜索时遭遇网络故障: {err}"


def calculator(expression: str) -> str:
    """工具 2：高精度安全数学计算器"""
    logger.info(f"   [Agent Tool] 🧮 正在解析表达式: \"{expression}\" ...")
    cleaned = re.sub(r'[^0-9+\-*/().\s]', '', expression)
    if not cleaned.strip():
        return f"【数学计算反馈】错误：表达式 \"{expression}\" 包含非法字符被拦截。"
    try:
        result = eval(cleaned, {"__builtins__": None}, {})
        return f"【数学计算反馈】计算结果：{expression} = {result}"
    except Exception as err:
        return f"【数学计算反馈】数学计算失败: {err}"


def generate_image(prompt: str) -> str:
    """工具 3：图像生成工具，能根据画风、内容描述自动生成一张学习计划图或插图"""
    logger.info(f"   [Agent Tool] 🎨 正在进行 AI 图像生成: \"{prompt}\" ...")
    agnes_key = os.getenv("AGNES_API_KEY")
    
    if not agnes_key:
        # 离线或未配 Key 时的滑平降级占位图
        mock_seed = abs(hash(prompt)) % 1000
        mock_url = f"https://picsum.photos/seed/{mock_seed}/500/350"
        logger.info(f"      [Offline Mock] 未配置 AGNES_API_KEY，降级使用模拟 URL: {mock_url}")
        return f"【绘图工具反馈】图片生成成功！图片URL为：{mock_url} 。请在最终答案中以 Markdown 格式 `![学习大纲插图]({mock_url})` 呈现给用户。"
        
    try:
        # 使用 SDK 方式调用相兼容的 Agnes AI 图像生成接口
        client = OpenAI(api_key=agnes_key, base_url="https://apihub.agnes-ai.com/v1")
        response = client.images.generate(
            model="agnes-image-2.1-flash",
            prompt=prompt,
            n=1
        )
        image_url = response.data[0].url
        logger.info(f"      [Agnes AI] 图像生成成功，URL: {image_url}")
        return f"【绘图工具反馈】图片生成成功！图片URL为：{image_url} 。请在最终答案中以 Markdown 格式 `![插图]({image_url})` 呈现给用户。"
    except Exception as err:
        logger.error(f"      [Agnes AI] 图像生成失败: {err}")
        return f"【绘图工具反馈】图像生成失败: {err}"


def execute_tool(name: str, arguments_str: str) -> str:
    """物理工具中央分发中心"""
    arg = arguments_str.strip().strip("'\"")
    if name == "search_web":
        return search_web(arg)
    elif name == "calculator":
        return calculator(arg)
    elif name == "generate_image":
        return generate_image(arg)
    else:
        return f"❌ 未找到名为 '{name}' 的本地工具。"



# ==========================================
# 4. 设计 ReAct 提示词与状态解析器 📝
# ==========================================
AGENT_SYSTEM_PROMPT = """你是一个具备思考和工具执行能力的 AI 智能学习计划制定助手 (Study Planner Agent)。
你必须通过以下步骤来帮助用户解决复杂的学习目标，并量身定做一个精美的学习计划。

你拥有的本地物理工具如下：
1. `search_web`: 联网搜索最新资讯、学习大纲、技术路线图等。参数为纯文本关键词。
2. `calculator`: 计算学习天数、学习时长与里程碑计划。参数为四则运算算式。
3. `generate_image`: 绘图工具，能根据画风、内容描述自动生成一张相关的学习计划图或大纲插图。参数为画面的具体描述词，如“一个打字写代码的卡通龙虾”。

你运行在一个经典的 ReAct 循环中。在每一步的交互中，你必须并且只能输出以下三种格式之一：

--- 格式 A（当你需要调用工具时）：
Thought: [说明你为什么需要调用工具，以及要查什么]
Action: [必须是 search_web, calculator 或 generate_image 之一]
Action Input: [传递给工具的具体参数值]

注意：输出完 Action Input 之后，你必须立即停止输出，等待本地环境运行该工具并反馈结果给你。绝对不能自己编造 Observation！

--- 格式 B（当所有信息收集完毕，准备输出最终学习计划时）：
Thought: [说明我已经获得了足够的信息，开始生成计划]
Final Answer: [你给用户的最终详细学习计划，请使用排版精美的 Markdown 格式]

--- 格式 C（闲聊/常规问答无需工具时）：
Thought: [说明我可以直接回答]
Final Answer: [常规答复]
"""

def parse_react_response(text: str) -> Tuple[str, Any]:
    """解析 ReAct 输出"""
    final_match = re.search(r"Final Answer:\s*(.*)", text, re.DOTALL)
    if final_match:
        return "final", final_match.group(1).strip()
    
    action_match = re.search(r"Action:\s*(\w+)", text)
    action_input_match = re.search(r"Action Input:\s*(.*)", text, re.DOTALL)
    
    if action_match and action_input_match:
        action = action_match.group(1).strip()
        action_input = action_input_match.group(1).strip()
        if "Observation:" in action_input:
            action_input = action_input.split("Observation:")[0].strip()
        return "action", (action, action_input)
        
    return "chat", text.strip()


# ==========================================
# 5. 创建 FastAPI 与数据契约 🚀
# ==========================================
app = FastAPI(
    title="星火 RAG + Agent 综合服务端",
    description="集成 PDF RAG 伴读与 ReAct 学习计划 Agent 接口的高性能后端",
    version="1.2.0"
)

class QueryRequest(BaseModel):
    question: str

class UploadResponse(BaseModel):
    status: str
    filename: str
    chunks_count: int
    message: str


@app.get("/health")
def health_check():
    try:
        chroma_client.list_collections()
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}


@app.post("/upload", response_model=UploadResponse)
async def upload_pdf(file: UploadFile = File(...)):
    """PDF 上传切片接口"""
    logger.info(f"接收到文件上传请求: {file.filename}")
    if not file.filename.endswith(".pdf"):
        raise HTTPException(status_code=400, detail="只允许上传 .pdf 格式的文件。")
        
    try:
        contents = await file.read()
        pdf_stream = io.BytesIO(contents)
        reader = PdfReader(pdf_stream)
        
        full_text = ""
        for page in reader.pages:
            page_text = page.extract_text() or ""
            page_text_clean = " ".join(page_text.split())
            full_text += page_text_clean + "\n\n"
            
        if not full_text.strip():
            raise HTTPException(status_code=400, detail="PDF 文件内容为空。")

        splitter = RecursiveCharacterTextSplitter(
            chunk_size=350,
            chunk_overlap=50,
            length_function=len
        )
        chunks = splitter.split_text(full_text)

        try:
            chroma_client.delete_collection(name=COLLECTION_NAME)
        except Exception:
            pass
            
        collection = chroma_client.create_collection(name=COLLECTION_NAME)
        embeddings = get_embeddings(chunks)
        ids = [f"pdf_chunk_{i+1}" for i in range(len(chunks))]
        collection.add(
            embeddings=embeddings,
            documents=chunks,
            ids=ids
        )
        return UploadResponse(status="success", filename=file.filename, chunks_count=len(chunks), message="向量索引重建成功！")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"建库失败: {str(e)}")


async def sse_event_generator(question: str):
    """RAG 流式应答生成器 (兼容 Day 23)"""
    try:
        collection = chroma_client.get_collection(name=COLLECTION_NAME)
    except Exception:
        yield f"data: {json.dumps({'type': 'error', 'message': '知识库为空，请先上传 PDF 建库。'})}\n\n"
        return

    llm_client, model_name, provider = get_llm_client_and_model()
    rewritten_question = question
    
    if llm_client and len(question) >= 8:
        try:
            rewrite_prompt = (
                "你是一个高效的搜索查询改写助手。你的任务是将用户输入的复杂提问，"
                "改写为1个最适合在公司管理制度文档中进行语义向量检索的纯净、标准的搜索词。\n"
                f"输入：‘{question}’"
            )
            rewrite_resp = llm_client.chat.completions.create(
                model=model_name,
                messages=[{"role": "user", "content": rewrite_prompt}],
                max_tokens=30,
                temperature=0.0
            )
            rewritten_question = rewrite_resp.choices[0].message.content.strip().replace('"', '').replace('\'', '')
        except Exception:
            pass

    try:
        query_vector = get_embeddings([rewritten_question])[0]
        results = collection.query(query_embeddings=[query_vector], n_results=3)
        retrieved_chunks = results.get("documents", [[]])[0]
    except Exception as e:
        yield f"data: {json.dumps({'type': 'error', 'message': f'数据库检索错误: {str(e)}'})}\n\n"
        return

    yield f"data: {json.dumps({'type': 'metadata', 'question': question, 'rewritten_question': rewritten_question, 'retrieved_chunks': retrieved_chunks})}\n\n"
    await asyncio.sleep(0.01)

    if not retrieved_chunks:
        yield f"data: {json.dumps({'type': 'content', 'delta': '未能在知识库中找到相关参考依据。'})}\n\n"
        yield f"data: {json.dumps({'type': 'end'})}\n\n"
        return

    context_text = "\n\n".join(retrieved_chunks)
    system_prompt = (
        "你是一个客观严谨的公司私有政策伴读助手。请根据下方提供的【真实参考背景】来回答用户的提问。\n"
        "如果用户的提问无法从【参考背景】中合理推断出来，请诚实地说明你无法回答，绝对不能进行无中生有的幻觉瞎编！\n"
        "回答必须专业简洁，并使用精美的 Markdown 格式输出。\n\n"
        f"【真实参考背景】：\n{context_text}"
    )

    if llm_client:
        try:
            stream = llm_client.chat.completions.create(
                model=model_name,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": f"问题：{question}"}
                ],
                temperature=0.3,
                stream=True
            )
            for chunk in stream:
                delta = chunk.choices[0].delta.content or ""
                if delta:
                    yield f"data: {json.dumps({'type': 'content', 'delta': delta})}\n\n"
                    await asyncio.sleep(0.005)
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': f'连接中断: {str(e)}'})}\n\n"
            return
    else:
        fallback_text = f"⚠️ 【当前处于断网离线仿真模式】\n\n已匹配到证据：\n\n{context_text}"
        for i in range(0, len(fallback_text), 4):
            yield f"data: {json.dumps({'type': 'content', 'delta': fallback_text[i:i+4]})}\n\n"
            await asyncio.sleep(0.02)

    yield f"data: {json.dumps({'type': 'end'})}\n\n"


@app.post("/stream_query")
def stream_query(request: QueryRequest):
    return StreamingResponse(sse_event_generator(request.question), media_type="text/event-stream")


class ImageRequest(BaseModel):
    prompt: str


@app.post("/generate_image")
async def api_generate_image(request: ImageRequest):
    """
    提供给他人/外部系统直接调用的图像生成 API 接口
    - 请求体: {"prompt": "画面描述"}
    - 返回值: {"status": "success", "url": "图片下载链接"}
    """
    logger.info(f"接收到外部图像生成 API 调用, 提示词: '{request.prompt}'")
    agnes_key = os.getenv("AGNES_API_KEY")
    
    if not agnes_key:
        # 降级模拟占位图
        mock_seed = abs(hash(request.prompt)) % 1000
        mock_url = f"https://picsum.photos/seed/{mock_seed}/500/350"
        return {
            "status": "success",
            "provider": "mock",
            "url": mock_url,
            "message": "提示：当前未配 AGNES_API_KEY 环境变量，以离线占位图模式返回。"
        }
        
    try:
        client = OpenAI(api_key=agnes_key, base_url="https://apihub.agnes-ai.com/v1")
        response = client.images.generate(
            model="agnes-image-2.1-flash",
            prompt=request.prompt,
            n=1
        )
        image_url = response.data[0].url
        return {
            "status": "success",
            "provider": "agnes-ai",
            "url": image_url
        }
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"图像生成失败: {str(err)}")



# ==========================================
# 6. SSE Agent Planner 核心异步生成器 🌊
# ==========================================
async def agent_event_generator(question: str):
    """
    异步生成器，输出 Agent 运行时的中间推理状态与最终流式回答。
    """
    llm_client, model_name, provider = get_llm_client_and_model()
    
    # 初始化会话历史
    history = [
        {"role": "system", "content": AGENT_SYSTEM_PROMPT},
        {"role": "user", "content": f"Question: {question}"}
    ]
    
    max_steps = 6
    step = 1
    answered = False
    
    logger.info(f"启动 Agent 规划工作流，目标: '{question}'")
    
    while step <= max_steps and not answered:
        logger.info(f"Agent 迭代 [第 {step}/{max_steps} 步]...")
        
        # 1. 如果离线，则直接降级输出模拟学习计划
        if not llm_client:
            thought = "检测到无 API Key，我需要结合本地经验直接为用户规划一个通用的 30 天学习计划。"
            yield f"data: {json.dumps({'type': 'thought', 'content': thought})}\n\n"
            await asyncio.sleep(0.5)
            
            yield f"data: {json.dumps({'type': 'action', 'name': 'calculator', 'input': '30 / 4'})}\n\n"
            await asyncio.sleep(0.5)
            
            yield f"data: {json.dumps({'type': 'observation', 'content': '【数学计算反馈】计算结果：30 / 4 = 7.5 (每周安排7.5天学习)'})}\n\n"
            await asyncio.sleep(0.5)
            
            final_plan = (
                f"## 📖 30 天学习计划定制（离线仿真版）\n\n"
                f"针对您的学习目标：**{question}**，制定如下周迭代计划：\n\n"
                f"*   **第 1 周：基础入门与概念突破**\n"
                f"    *   打通开发环境，掌握核心语法和基本配置。\n"
                f"*   **第 2 周：核心模块开发与实战演练**\n"
                f"    *   完成项目基础组件编写，跑通主线流程。\n"
                f"*   **第 3 周：高级框架接入与优化**\n"
                f"    *   学习图状态机、工具扩展以及性能调试。\n"
                f"*   **第 4 周：综合大项目交付与总结**\n"
                f"    *   完成一键部署、界面联调并整理技术笔记。"
            )
            for i in range(0, len(final_plan), 5):
                yield f"data: {json.dumps({'type': 'content', 'delta': final_plan[i:i+5]})}\n\n"
                await asyncio.sleep(0.01)
            answered = True
            break

        # 2. 在线决策阶段
        try:
            response = llm_client.chat.completions.create(
                model=model_name,
                messages=history,
                stop=["Observation:", "observation:"],  # 遇到 Observation 自动熔断，确保本地拦截
                temperature=0.2
            )
            llm_text = response.choices[0].message.content.strip()
            
            # 解析输出的 ReAct 状态
            result_type, content = parse_react_response(llm_text)
            
            if result_type == "action":
                action_name, action_input = content
                # 提取 Thought 部分发送给客户端
                thought = llm_text.split("Action:")[0].replace("Thought:", "").strip()
                
                yield f"data: {json.dumps({'type': 'thought', 'content': thought})}\n\n"
                await asyncio.sleep(0.05)
                
                yield f"data: {json.dumps({'type': 'action', 'name': action_name, 'input': action_input})}\n\n"
                await asyncio.sleep(0.05)
                
                # 物理执行本地代码，捕获观察结果
                observation = execute_tool(action_name, action_input)
                
                yield f"data: {json.dumps({'type': 'observation', 'content': observation})}\n\n"
                await asyncio.sleep(0.05)
                
                # 回写历史上下文
                history.append({"role": "assistant", "content": llm_text})
                history.append({"role": "user", "content": f"Observation: {observation}"})
                
            elif result_type == "final":
                final_answer = content
                thought = llm_text.split("Final Answer:")[0].replace("Thought:", "").strip()
                
                if thought:
                    yield f"data: {json.dumps({'type': 'thought', 'content': thought})}\n\n"
                    await asyncio.sleep(0.05)
                    
                # 将最终学习计划以打字机流式推送
                for i in range(0, len(final_answer), 5):
                    yield f"data: {json.dumps({'type': 'content', 'delta': final_answer[i:i+5]})}\n\n"
                    await asyncio.sleep(0.005)
                answered = True
                
            else:
                # 兜底降级推送
                for i in range(0, len(content), 5):
                    yield f"data: {json.dumps({'type': 'content', 'delta': content[i:i+5]})}\n\n"
                    await asyncio.sleep(0.005)
                answered = True
                
        except Exception as e:
            logger.error(f"Agent 推演故障: {e}")
            yield f"data: {json.dumps({'type': 'error', 'message': f'Agent 推理发生故障: {str(e)}'})}\n\n"
            return
            
        step += 1

    if not answered:
        yield f"data: {json.dumps({'type': 'error', 'message': '智能体迭代次数过多已强制熔断！'})}\n\n"
    else:
        yield f"data: {json.dumps({'type': 'end'})}\n\n"


@app.post("/stream_agent")
def stream_agent(request: QueryRequest):
    """
    RAG + Agent 学习计划生成接口 (SSE)
    - 接收提问，流式返回智能体的所有思考、行动过程，以及最终的学习计划
    """
    logger.info(f"接收到智能学习计划生成请求: '{request.question}'")
    return StreamingResponse(
        agent_event_generator(request.question),
        media_type="text/event-stream"
    )


# ==========================================
# 7. 启动服务器 🏃‍♂️
# ==========================================
if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
