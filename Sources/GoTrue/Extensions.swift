import Get

extension SessionOrUser {

  public var user: User? {
    if case .user(let user) = self { return user }
    return nil
  }

  public var session: Session? {
    if case .session(let session) = self { return session }
    return nil
  }
}

extension Request {
  func withAuthoriztion(_ token: String) -> Self {
    var copy = self
    var headers = copy.headers ?? [:]
    headers["Authorization"] = "Bearer \(token)"
    copy.headers = headers
    return copy
  }
}
