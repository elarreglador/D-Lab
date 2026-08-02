module.exports = {
  httpAdminRoot: '/',
  httpNodeRoot: '/',
  uiPort: 1880,
  userDir: '/data',
  flowFile: 'flows.json',
  credentialSecret: '__CREDENTIAL_SECRET__',
  adminAuth: {
    type: "credentials",
    users: [
      {
        username: "elarreglador",
        password: "__ADMIN_HASH__",
        permissions: "*"
      }
    ]
  },
  logging: {
    console: {
      level: "info",
      metrics: false,
      audit: false
    }
  },
  editorTheme: {
    projects: {
      enabled: false
    }
  }
};
