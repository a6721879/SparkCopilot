//
//  RAGManager.swift
//  day26-swiftui-client
//
//  Created by 宋时成 on 2026/06/04.
//

import Foundation
import Combine

enum MessageSender {
    case user
    case assistant
}

// 智能体单步思考模型
struct AgentStep: Identifiable, Codable {
    let id = UUID()
    var thought: String = ""
    var actionName: String? = nil
    var actionInput: String? = nil
    var observation: String? = nil
    var isCompleted: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case thought, actionName, actionInput, observation, isCompleted
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let sender: MessageSender
    var content: String
    var isStreaming: Bool = false
    
    // RAG 相关元数据
    var rewrittenQuestion: String? = nil
    var retrievedChunks: [String] = []
    
    // Agent 相关中间思考链轨迹
    var agentSteps: [AgentStep] = []
    
    // 解析出消息内容里的所有图片 URL 链接
    var imageUrls: [URL] {
        let pattern = "!\\[.*?\\]\\(((https?://[\\w\\d:\\#@%/;$()~_?\\+-=\\\\\\.&]*))\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsString = content as NSString
        let results = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsString.length))
        return results.compactMap { result in
            if result.numberOfRanges >= 2 {
                let urlString = nsString.substring(with: result.range(at: 1))
                return URL(string: urlString)
            }
            return nil
        }
    }
    
    // 过滤掉 Markdown 图片标记后的纯净文本，防止原生渲染器二次绘制
    var cleanTextContent: String {
        let pattern = "!\\[.*?\\]\\((https?://[\\w\\d:\\#@%/;$()~_?\\+-=\\\\\\.&]*)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return content }
        let mutableString = NSMutableString(string: content)
        regex.replaceMatches(in: mutableString, options: [], range: NSRange(location: 0, length: mutableString.length), withTemplate: "")
        return (mutableString as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// SSE 解析结构体
struct SSEMetadataPayload: Codable {
    let type: String
    let question: String
    let rewrittenQuestion: String
    let retrievedChunks: [String]
    
    enum CodingKeys: String, CodingKey {
        case type, question
        case rewrittenQuestion = "rewritten_question"
        case retrievedChunks = "retrieved_chunks"
    }
}

struct SSEContentPayload: Codable {
    let type: String
    let delta: String
}

struct SSEThoughtPayload: Codable {
    let type: String
    let content: String
}

struct SSEActionPayload: Codable {
    let type: String
    let name: String
    let input: String
}

struct SSEObservationPayload: Codable {
    let type: String
    let content: String
}

struct SSEErrorPayload: Codable {
    let type: String
    let message: String
}

@MainActor
class RAGManager: ObservableObject {
    @Published var messages: [ChatMessage] = []          // RAG Tab 消息列表
    @Published var agentMessages: [ChatMessage] = []     // Agent Tab 消息列表
    
    @Published var isUploading = false
    @Published var uploadStatus = ""
    @Published var isQuerying = false
    @Published var isPlanning = false
    
    private let baseURL = "http://10.10.9.224:8000"
    
    init() {
        // RAG 初始化消息
        messages.append(ChatMessage(
            sender: .assistant,
            content: "👋 您好！我是您的 PDF 伴读助手。请导入 PDF 课本/文档，随后我将基于文档为您流式解答问题！"
        ))
        
        // Agent 初始化消息
        agentMessages.append(ChatMessage(
            sender: .assistant,
            content: "👋 您好！我是您的智能学习计划生成 Agent。\n请输入您的学习目标或岗位方向（例如：“我想在 30 天内速成 Python 开发”），我将在后台利用联网搜索、天数计算等工具，边思考边为您定制全套里程碑学习计划！"
        ))
    }
    
    // ==========================================
    // 1. PDF 向量库操作与 RAG 接口联调 (同 Day 24)
    // ==========================================
    func uploadPDF(fileURL: URL) async {
        let hasAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        self.isUploading = true

        self.uploadStatus = "正在读取 PDF 文件数据..."
        
        do {
            let fileData = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent
            
            let boundary = "Boundary-\(UUID().uuidString)"
            var request = URLRequest(url: URL(string: "\(baseURL)/upload")!)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
            
            self.uploadStatus = "正在向后端发送并重新构建向量知识库..."
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.uploadStatus = "❌ 向量库重建异常，请确认服务器在线。"
                self.isUploading = false
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let count = json["chunks_count"] as? Int {
                self.uploadStatus = "✅ 成功重建向量索引: \(filename) | 切为 \(count) 个片段！"
            } else {
                self.uploadStatus = "✅ 向量库重建成功！"
            }
        } catch {
            self.uploadStatus = "❌ 导入异常: \(error.localizedDescription)"
        }
        self.isUploading = false
    }
    
    func sendMessage(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        self.messages.append(ChatMessage(sender: .user, content: trimmed))
        self.isQuerying = true
        
        var assistantMsg = ChatMessage(sender: .assistant, content: "🧠 大脑检索资料中...", isStreaming: true)
        self.messages.append(assistantMsg)
        let index = self.messages.count - 1
        
        guard let url = URL(string: "\(baseURL)/stream_query") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(["question": trimmed])
        
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.messages[index].content = "❌ 伴读接口异常，请确保后端服务启动。"
                self.messages[index].isStreaming = false
                self.isQuerying = false
                return
            }
            
            self.messages[index].content = ""
            let decoder = JSONDecoder()
            
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = payload.data(using: .utf8) else { continue }
                
                if let metadata = try? decoder.decode(SSEMetadataPayload.self, from: data) {
                    self.messages[index].rewrittenQuestion = metadata.rewrittenQuestion
                    self.messages[index].retrievedChunks = metadata.retrievedChunks
                } else if let content = try? decoder.decode(SSEContentPayload.self, from: data) {
                    self.messages[index].content += content.delta
                } else if let errPayload = try? decoder.decode(SSEErrorPayload.self, from: data) {
                    self.messages[index].content = "❌ 错误: \(errPayload.message)"
                } else if line.contains("\"type\": \"end\"") {
                    break
                }
            }
        } catch {
            self.messages[index].content = "❌ 异常: \(error.localizedDescription)"
        }
        self.messages[index].isStreaming = false
        self.isQuerying = false
    }
    
    // ==========================================
    // 2. 智能计划生成 Agent 接口联调 (SSE 状态机推送)
    // ==========================================
    func sendAgentMessage(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // 1. 追加用户提问
        self.agentMessages.append(ChatMessage(sender: .user, content: trimmed))
        self.isPlanning = true
        
        // 2. 追加 AI 占位消息，初始化空思考步骤列表
        var assistantMsg = ChatMessage(
            sender: .assistant,
            content: "🤖 智能体正在启动规划回路...",
            isStreaming: true,
            agentSteps: []
        )
        self.agentMessages.append(assistantMsg)
        let index = self.agentMessages.count - 1
        
        // 3. 构建请求
        guard let url = URL(string: "\(baseURL)/stream_agent") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(["question": trimmed])
        
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.agentMessages[index].content = "❌ 计划生成接口异常，请确保后端服务运行在 8000 端口。"
                self.agentMessages[index].isStreaming = false
                self.isPlanning = false
                return
            }
            
            // 清理状态提示语，准备接收动态流
            self.agentMessages[index].content = ""
            let decoder = JSONDecoder()
            
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = payload.data(using: .utf8) else { continue }
                
                if let thoughtPayload = try? decoder.decode(SSEThoughtPayload.self, from: data) {
                    // ① 收到思考帧 ➔ 开启一个新的 AgentStep 状态项
                    let newStep = AgentStep(thought: thoughtPayload.content)
                    self.agentMessages[index].agentSteps.append(newStep)
                    
                } else if let actionPayload = try? decoder.decode(SSEActionPayload.self, from: data) {
                    // ② 收到行动帧 ➔ 更新最后一个状态项的 Tool 名字与入参
                    if !self.agentMessages[index].agentSteps.isEmpty {
                        let lastIdx = self.agentMessages[index].agentSteps.count - 1
                        self.agentMessages[index].agentSteps[lastIdx].actionName = actionPayload.name
                        self.agentMessages[index].agentSteps[lastIdx].actionInput = actionPayload.input
                    }
                    
                } else if let obsPayload = try? decoder.decode(SSEObservationPayload.self, from: data) {
                    // ③ 收到观察帧 ➔ 更新最后一个状态项的执行结果，置为 Completed
                    if !self.agentMessages[index].agentSteps.isEmpty {
                        let lastIdx = self.agentMessages[index].agentSteps.count - 1
                        self.agentMessages[index].agentSteps[lastIdx].observation = obsPayload.content
                        self.agentMessages[index].agentSteps[lastIdx].isCompleted = true
                    }
                    
                } else if let contentPayload = try? decoder.decode(SSEContentPayload.self, from: data) {
                    // ④ 收到内容增量帧 ➔ 开始以打字机输出最后的学习计划 Markdown
                    self.agentMessages[index].content += contentPayload.delta
                    
                } else if let errPayload = try? decoder.decode(SSEErrorPayload.self, from: data) {
                    self.agentMessages[index].content = "❌ 规划中断：\(errPayload.message)"
                    
                } else if line.contains("\"type\": \"end\"") {
                    // 到达结束标志
                    break
                }
            }
        } catch {
            self.agentMessages[index].content = "❌ 网络推演中断: \(error.localizedDescription)"
        }
        
        self.agentMessages[index].isStreaming = false
        self.isPlanning = false
    }
    
    func clearRAGHistory() {
        self.messages = [ChatMessage(
            sender: .assistant,
            content: "👋 PDF 伴读会话历史已清除。请上传 PDF 重新开始学习吧！"
        )]
    }
    
    func clearAgentHistory() {
        self.agentMessages = [ChatMessage(
            sender: .assistant,
            content: "👋 学习计划生成历史已清除。请输入您新的开发方向重新定制计划吧！"
        )]
    }
}
