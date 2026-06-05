//
//  ContentView.swift
//  day26-swiftui-client
//
//  Created by 宋时成 on 2026/06/04.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var ragManager = RAGManager()
    @State private var activeTab = 0
    
    var body: some View {
        TabView(selection: $activeTab) {
            // Tab 1: PDF 伴读 (PDF Copilot RAG)
            RAGCopilotView(ragManager: ragManager)
                .tabItem {
                    Label("伴读 Copilot", systemImage: "book.closed.fill")
                }
                .tag(0)
            
            // Tab 2: 学习计划生成器 (Agent Planner)
            AgentPlannerView(ragManager: ragManager)
                .tabItem {
                    Label("学习规划器", systemImage: "map.fill")
                }
                .tag(1)
        }
        .accentColor(.blue)
    }
}

// ==========================================
// 1. Tab 1: RAG 智能伴读视图
// ==========================================
struct RAGCopilotView: View {
    @ObservedObject var ragManager: RAGManager
    @State private var inputText = ""
    @State private var showFileImporter = false
    @State private var expandedMessageIDs: Set<UUID> = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 超薄状态提示条（仅在有上传状态时显示）
                if ragManager.isUploading || !ragManager.uploadStatus.isEmpty {
                    HStack {
                        if ragManager.isUploading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 4)
                            Text("正在解析 PDF 并建立索引...")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } else {
                            Text(ragManager.uploadStatus)
                                .font(.system(size: 12))
                                .foregroundColor(.blue)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                }
                
                // 消息滚动区
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(ragManager.messages) { msg in
                                MessageBubbleView(
                                    message: msg,
                                    isExpanded: expandedMessageIDs.contains(msg.id),
                                    onExpandToggle: {
                                        if expandedMessageIDs.contains(msg.id) {
                                            expandedMessageIDs.remove(msg.id)
                                        } else {
                                            expandedMessageIDs.insert(msg.id)
                                        }
                                    }
                                )
                                .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: ragManager.messages.count) { _ in
                        withAnimation {
                            if let lastID = ragManager.messages.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: ragManager.messages.last?.content) { _ in
                        if let lastMsg = ragManager.messages.last, lastMsg.isStreaming {
                            proxy.scrollTo(lastMsg.id, anchor: .bottom)
                        }
                    }
                }
                
                Divider()
                
                // 输入框栏
                HStack(spacing: 8) {
                    TextField("向 AI 伴读询问关于 PDF 的内容...", text: $inputText)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .disabled(ragManager.isQuerying)
                        .onSubmit { submitQuestion() }
                    
                    if ragManager.isQuerying {
                        ProgressView()
                            .padding(.horizontal, 8)
                    } else {
                        Button(action: submitQuestion) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(inputText.isEmpty ? Color.gray : Color.blue)
                                .clipShape(Circle())
                        }
                        .disabled(inputText.isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("星火伴读 Copilot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showFileImporter = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.badge.plus")
                            Text("导入 PDF")
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .disabled(ragManager.isUploading)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { ragManager.clearRAGHistory() }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        Task { await ragManager.uploadPDF(fileURL: url) }
                    }
                case .failure(let err):
                    ragManager.uploadStatus = "❌ 导入失败: \(err.localizedDescription)"
                }
            }
        }
    }
    
    private func submitQuestion() {
        let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        inputText = ""
        Task { await ragManager.sendMessage(q) }
    }
}

// ==========================================
// 2. Tab 2: Agent 智能学习规划器视图
// ==========================================
struct AgentPlannerView: View {
    @ObservedObject var ragManager: RAGManager
    @State private var inputText = ""
    @State private var expandedStepMessageIDs: Set<UUID> = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 超薄状态提示条
                if ragManager.isPlanning {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(.trailing, 4)
                        Text("智能体规划中，正调用工具...")
                            .font(.system(size: 12))
                            .foregroundColor(.purple)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                }
                
                // 消息滚动区
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(ragManager.agentMessages) { msg in
                                AgentMessageBubbleView(
                                    message: msg,
                                    isStepsExpanded: expandedStepMessageIDs.contains(msg.id),
                                    onStepsToggle: {
                                        if expandedStepMessageIDs.contains(msg.id) {
                                            expandedStepMessageIDs.remove(msg.id)
                                        } else {
                                            expandedStepMessageIDs.insert(msg.id)
                                        }
                                    }
                                )
                                .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: ragManager.agentMessages.count) { _ in
                        withAnimation {
                            if let lastID = ragManager.agentMessages.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: ragManager.agentMessages.last?.content) { _ in
                        // 如果最后一条是 AI 流式消息，保持贴底滚动
                        if let lastMsg = ragManager.agentMessages.last, lastMsg.isStreaming {
                            proxy.scrollTo(lastMsg.id, anchor: .bottom)
                        }
                    }
                }
                
                Divider()
                
                // 输入框栏
                HStack(spacing: 8) {
                    TextField("输入您想学习的内容（如：30天速成鸿蒙应用开发）...", text: $inputText)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .disabled(ragManager.isPlanning)
                        .onSubmit { submitObjective() }
                    
                    if ragManager.isPlanning {
                        ProgressView()
                            .padding(.horizontal, 8)
                    } else {
                        Button(action: submitObjective) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(inputText.isEmpty ? Color.gray : Color.purple)
                                .clipShape(Circle())
                        }
                        .disabled(inputText.isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("智能学习规划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { ragManager.clearAgentHistory() }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }
    
    private func submitObjective() {
        let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        inputText = ""
        // 新增的智能体对话默认自动展开它的思考轨迹
        Task {
            await ragManager.sendAgentMessage(q)
            if let lastMsg = ragManager.agentMessages.last {
                expandedStepMessageIDs.insert(lastMsg.id)
            }
        }
    }
}

// ==========================================
// 3. 子视图：Agent 专属聊天气泡 (支持时间轴脑回路)
// ==========================================
struct AgentMessageBubbleView: View {
    let message: ChatMessage
    let isStepsExpanded: Bool
    let onStepsToggle: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.sender == .user {
                Spacer(minLength: 40)
            } else {
                Image(systemName: "wand.and.stars.inverse")
                    .foregroundColor(.purple)
                    .font(.system(size: 18))
                    .padding(8)
                    .background(Color.purple.opacity(0.1))
                    .clipShape(Circle())
            }
            
            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 12) {
                if message.sender == .user {
                    // 用户气泡
                    Text(message.content)
                        .font(.system(size: 15))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .foregroundColor(.white)
                        .background(Color.purple)
                        .cornerRadius(16, corners: UIRectCorner([.topLeft, .topRight, .bottomLeft]))
                } else {
                    // 助手气泡
                    VStack(alignment: .leading, spacing: 10) {
                        
                        // ① 思考链轨迹抽屉 (The Reasoning Timeline)
                        if !message.agentSteps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Button(action: onStepsToggle) {
                                    HStack {
                                        Image(systemName: isStepsExpanded ? "brain.head.profile.fill" : "brain.fill")
                                            .foregroundColor(.purple)
                                        Text(message.isStreaming && message.content.isEmpty ? "AI 智能体正在规划脑补中..." : "🧠 大脑思考与规划轨迹 (\(message.agentSteps.count)步)")
                                        Spacer()
                                        Image(systemName: isStepsExpanded ? "chevron.up" : "chevron.down")
                                            .font(.caption)
                                    }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.purple)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(Color.purple.opacity(0.08))
                                    .cornerRadius(6)
                                }
                                
                                if isStepsExpanded {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(0..<message.agentSteps.count, id: \.self) { idx in
                                            let step = message.agentSteps[idx]
                                            HStack(alignment: .top, spacing: 8) {
                                                // 时间轴线和图标
                                                VStack(spacing: 4) {
                                                    Circle()
                                                        .fill(step.isCompleted ? Color.green : Color.orange)
                                                        .frame(width: 8, height: 8)
                                                    
                                                    if idx != message.agentSteps.count - 1 {
                                                        Rectangle()
                                                            .fill(Color(.systemGray4))
                                                            .frame(width: 1, height: 35)
                                                    }
                                                }
                                                .padding(.top, 4)
                                                
                                                // 单步思考与行动渲染
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("步骤 \(idx + 1) | 决策分析")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundColor(.secondary)
                                                    
                                                    // 思考 (Thought)
                                                    Text(step.thought)
                                                        .font(.system(size: 11))
                                                        .foregroundColor(Color(.darkGray))
                                                        .padding(6)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(Color(.systemGray6))
                                                        .cornerRadius(4)
                                                    
                                                    // 行动 (Action)
                                                    if let actName = step.actionName, let actInput = step.actionInput {
                                                        HStack(spacing: 4) {
                                                            Image(systemName: "gearshape.fill")
                                                                .rotationEffect(.degrees(step.isCompleted ? 360 : 0))
                                                                .animation(step.isCompleted ? .none : .linear(duration: 2).repeatForever(autoreverses: false), value: step.isCompleted)
                                                            Text("⚙️ 调用物理模块:")
                                                                .font(.system(size: 10, weight: .bold))
                                                            Text("\(actName)(\"\(actInput)\")")
                                                                .font(.system(size: 10))
                                                        }
                                                        .foregroundColor(.blue)
                                                        .padding(.top, 2)
                                                    }
                                                    
                                                    // 观察反馈 (Observation)
                                                    if let obs = step.observation {
                                                        Text("💾 捕获环境观测反馈：\n\(obs)")
                                                            .font(.system(size: 10))
                                                            .foregroundColor(.orange)
                                                            .padding(6)
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                            .background(Color(.systemYellow).opacity(0.08))
                                                            .cornerRadius(4)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.leading, 6)
                                    .padding(.top, 4)
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        
                        // ② 最终生成的学习大纲/计划 Markdown
                        if !message.cleanTextContent.isEmpty {
                            Text(message.cleanTextContent)
                                .font(.system(size: 14))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if message.isStreaming && message.imageUrls.isEmpty {
                            // 等待规划中的打字动画
                            HStack(spacing: 4) {
                                Text("✍️ AI 正在撰写专属大纲")
                                LoadingDotsView()
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        
                        // ③ 展示解析出来的插图列表
                        if !message.imageUrls.isEmpty {
                            VStack(spacing: 10) {
                                ForEach(message.imageUrls, id: \.self) { url in
                                    ChatImageView(imageUrl: url)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(8)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }
            }
            
            if message.sender == .user {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundColor(.purple)
                    .font(.system(size: 20))
                    .padding(.top, 4)
            } else {
                Spacer(minLength: 40)
            }
        }
    }
}

// 等待打字点动效
struct LoadingDotsView: View {
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Text(String(repeating: ".", count: dotCount + 1))
            .onReceive(timer) { _ in
                dotCount = (dotCount + 1) % 3
            }
            .frame(width: 20, alignment: .leading)
    }
}

// 伴读页签使用的普通聊天气泡，带引文检索白盒证据抽屉
struct MessageBubbleView: View {
    let message: ChatMessage
    let isExpanded: Bool
    let onExpandToggle: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.sender == .user {
                Spacer(minLength: 40)
            } else {
                Image(systemName: "cpu.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 18))
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Circle())
            }
            
            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 8) {
                // 气泡主要文字（使用过滤后的纯文本）
                let showText = message.cleanTextContent
                if !showText.isEmpty {
                    Text(showText)
                        .font(.system(size: 15))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .foregroundColor(message.sender == .user ? .white : .primary)
                        .background(
                            message.sender == .user ?
                            Color.blue : Color(.systemGray6)
                        )
                        .cornerRadius(16, corners: message.sender == .user ? UIRectCorner([.topLeft, .topRight, .bottomLeft]) : UIRectCorner([.topLeft, .topRight, .bottomRight]))
                }
                
                // 展示解析出来的插图列表
                if !message.imageUrls.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(message.imageUrls, id: \.self) { url in
                            ChatImageView(imageUrl: url)
                        }
                    }
                    .frame(maxWidth: 260) // 气泡内最大宽度限制
                    .padding(.vertical, 4)
                }
                
                // 大模型改写查询语句 & 召回证据白盒展示
                if message.sender == .assistant && !message.retrievedChunks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: onExpandToggle) {
                            HStack(spacing: 4) {
                                Image(systemName: isExpanded ? "chevron.down.square.fill" : "chevron.right.square.fill")
                                Text("📖 召回背景依据 (\(message.retrievedChunks.count)个片段)")
                                if let rewritten = message.rewrittenQuestion {
                                    Text("| 检索词: \"\(rewritten)\"")
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                }
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.blue)
                        }
                        
                        if isExpanded {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(0..<message.retrievedChunks.count, id: \.self) { idx in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("证据片段 [\(idx + 1)]:")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.secondary)
                                        Text(message.retrievedChunks[idx])
                                            .font(.system(size: 11))
                                            .foregroundColor(.primary)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(.systemGray6).opacity(0.5))
                                            .cornerRadius(6)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color(.systemGray4), lineWidth: 0.5)
                                            )
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            
            if message.sender == .user {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 20))
                    .padding(.top, 4)
            } else {
                Spacer(minLength: 40)
            }
        }
    }
}

// 圆角辅助扩展 (SwiftUI Helper)
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// ==========================================
// 4. AI 生成图片展示与保存组件 🎨
// ==========================================
struct ChatImageView: View {
    let imageUrl: URL
    @State private var isDetailPresented = false
    @State private var isSaving = false
    @State private var saveMessage = ""
    @State private var showToast = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 图片加载区
            AsyncImage(url: imageUrl) { phase in
                switch phase {
                case .empty:
                    HStack {
                        Spacer()
                        ProgressView("正在载入插图...")
                            .scaleEffect(0.8)
                        Spacer()
                    }
                    .frame(height: 150)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 180)
                        .clipped()
                        .cornerRadius(10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isDetailPresented = true
                        }
                case .failure:
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundColor(.gray)
                            Text("插图加载失败")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .frame(height: 120)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                @unknown default:
                    EmptyView()
                }
            }
            
            // 操作栏
            HStack {
                Spacer()
                Button(action: saveToAlbum) {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(isSaving ? "保存中..." : "保存到相册")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .foregroundColor(.blue)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
                .disabled(isSaving)
            }
        }
        .padding(6)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.systemGray5), lineWidth: 0.5)
        )
        // 放大预览 Modal
        .fullScreenCover(isPresented: $isDetailPresented) {
            ImagePreviewModal(imageUrl: imageUrl, isPresented: $isDetailPresented)
        }
        // Toast 消息提示
        .alert(isPresented: $showToast) {
            Alert(title: Text("提示"), message: Text(saveMessage), dismissButton: .default(Text("好的")))
        }
    }
    
    private func saveToAlbum() {
        self.isSaving = true
        URLSession.shared.dataTask(with: imageUrl) { data, _, error in
            guard let data = data, let image = UIImage(data: data) else {
                DispatchQueue.main.async {
                    self.saveMessage = "❌ 图片下载失败，请检查网络"
                    self.showToast = true
                    self.isSaving = false
                }
                return
            }
            
            DispatchQueue.main.async {
                let saver = ImageSaver { success in
                    self.isSaving = false
                    self.saveMessage = success ? "✅ 图片已成功保存至您的系统相册！" : "❌ 保存失败，请前往“设置-隐私”中开启相册写入权限。"
                    self.showToast = true
                }
                saver.writeToPhotoAlbum(image: image)
            }
        }.resume()
    }
}

// 大图预览模态框
struct ImagePreviewModal: View {
    let imageUrl: URL
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var isSaving = false
    @State private var saveMessage = ""
    @State private var showToast = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let delta = value / lastScale
                                        lastScale = value
                                        scale = min(max(scale * delta, 1.0), 4.0)
                                    }
                                    .onEnded { _ in
                                        lastScale = 1.0
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation {
                                    if scale > 1.0 {
                                        scale = 1.0
                                    } else {
                                        scale = 2.0
                                    }
                                }
                            }
                    case .failure:
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                            Text("无法载入大图")
                                .foregroundColor(.white)
                        }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle("插图预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { isPresented = false }) {
                        Text("关闭")
                            .foregroundColor(.white)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: saveToAlbum) {
                        HStack(spacing: 4) {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                            }
                            Text(isSaving ? "" : "保存")
                        }
                        .foregroundColor(.white)
                    }
                    .disabled(isSaving)
                }
            }
            .alert(isPresented: $showToast) {
                Alert(title: Text("提示"), message: Text(saveMessage), dismissButton: .default(Text("好的")))
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func saveToAlbum() {
        self.isSaving = true
        URLSession.shared.dataTask(with: imageUrl) { data, _, error in
            guard let data = data, let image = UIImage(data: data) else {
                DispatchQueue.main.async {
                    self.saveMessage = "❌ 图片数据下载失败"
                    self.showToast = true
                    self.isSaving = false
                }
                return
            }
            
            DispatchQueue.main.async {
                let saver = ImageSaver { success in
                    self.isSaving = false
                    self.saveMessage = success ? "✅ 图片已成功保存到您的系统相册！" : "❌ 保存失败，请确认已在设置中开启相册权限。"
                    self.showToast = true
                }
                saver.writeToPhotoAlbum(image: image)
            }
        }.resume()
    }
}

// 相册写入助手 (Objective-C 回调包装器)
class ImageSaver: NSObject {
    var completion: (Bool) -> Void
    
    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }
    
    func writeToPhotoAlbum(image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(saveCompleted), nil)
    }
    
    @objc func saveCompleted(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            print("保存图片出错: \(error.localizedDescription)")
            completion(false)
        } else {
            completion(true)
        }
    }
}
