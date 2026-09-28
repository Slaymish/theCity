import Foundation

extension FloorSnapshot {
    /// The office events that take a scene showing `old` to showing `self`, so the phone's robots move as the Mac's did.
    /// Steps between two snapshots are lost, which is fine for a glance. With no `old`, the scene has only just been built:
    /// it catches up on the running job quietly and shows a finished one as an idle office.
    public func events(since old: FloorSnapshot?) -> [OfficeEvent] {
        let newRun = old != nil && old?.startedAt != startedAt
        if old == nil, !isRunning { return [] }
        let before = newRun || old == nil ? FloorSnapshot.empty(like: self) : old!
        var out: [OfficeEvent] = []
        if newRun || old == nil || (before.phase != .running && phase == .running) { out.append(.runStarted) }

        let previous = Dictionary(uniqueKeysWithValues: before.handoffs.map { ($0.toolUseID, $0) })
        let catchingUp = old == nil
        for handoff in handoffs {
            let was = previous[handoff.toolUseID]
            if catchingUp, handoff.handedBack { continue }
            if was == nil { out.append(.handoff(toolUseID: handoff.toolUseID, room: handoff.room, description: handoff.brief)) }
            if handoff.phase != .requested, was.map({ $0.phase == .requested }) ?? true {
                out.append(.roomStarted(toolUseID: handoff.toolUseID, room: handoff.room))
            }
            if handoff.phase == .working, let step = handoff.step, step != was?.step {
                out.append(.roomActivity(room: handoff.room, toolName: handoff.lastTool ?? "", step: step))
            }
        }

        for (room, caption) in captions.sorted(by: { $0.key < $1.key }) where before.captions[room] != caption {
            out.append(.roomCaption(room: room, caption: caption))
        }
        for (room, skills) in skills.sorted(by: { $0.key < $1.key }) {
            for skill in skills where !(before.skills[room] ?? []).contains(skill) {
                out.append(.skillLoaded(room: room, skill: skill))
            }
        }

        let calls = Set(serviceCalls), oldCalls = Set(before.serviceCalls)
        for call in before.serviceCalls where !calls.contains(call) {
            out.append(.serviceCall(callID: call.callID, room: call.room, server: call.server, active: false))
        }
        for call in serviceCalls where !oldCalls.contains(call) {
            out.append(.serviceCall(callID: call.callID, room: call.room, server: call.server, active: true))
        }

        let asked = Set(questions.map(\.id)), wasAsked = Set(before.questions.map(\.id))
        for question in before.questions where !asked.contains(question.id) {
            out.append(.handLowered(requestID: question.id, room: question.room))
        }
        for question in questions where !wasAsked.contains(question.id) {
            out.append(.handRaised(question.request, room: question.room))
        }

        for handoff in handoffs {
            let was = previous[handoff.toolUseID]
            if catchingUp, handoff.handedBack { continue }
            if handoff.phase == .finished, was?.phase != .finished {
                out.append(.roomFinished(toolUseID: handoff.toolUseID, room: handoff.room, outcome: handoff.roomOutcome))
            }
            if handoff.handedBack, was?.handedBack != true {
                out.append(.handback(toolUseID: handoff.toolUseID, room: handoff.room, isError: handoff.outcome != .completed))
            }
        }

        if tokens != before.tokens || costUSD != before.costUSD {
            var tally = TokenTally()
            tally.usage = TokenUsage(input: 0, cacheCreation: 0, cacheRead: 0, output: tokens)
            tally.costUSD = costUSD
            tally.isFinal = !isRunning
            out.append(.tallyChanged(tally))
        }
        if managerActive != before.managerActive { out.append(.managerActive(managerActive)) }
        if let outcome = runOutcome, before.runOutcome == nil || newRun { out.append(.runEnded(outcome)) }
        return out
    }

    /// The same floor with nothing happening, as the starting point for a new run.
    static func empty(like floor: FloorSnapshot) -> FloorSnapshot {
        FloorSnapshot(id: floor.id, name: floor.name, hires: floor.hires, colours: floor.colours, request: nil, phase: .running, startedAt: floor.startedAt)
    }

    var runOutcome: RunOutcome? {
        switch phase {
        case .idle, .running: nil
        case .completed(let summary): .completed(summary: summary, costUSD: costUSD)
        case .cancelled: .cancelled(costUSD: costUSD)
        case .failed(let message): .failed(.runError(terminalReason: nil), message: message)
        }
    }
}

extension HandoffSnapshot {
    var roomOutcome: RoomOutcome {
        switch outcome {
        case .completed: .completed
        case .killed: .killed
        case .failed, nil: .failed("failed")
        }
    }
}
