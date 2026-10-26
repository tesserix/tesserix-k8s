let admin = db.getSiblingDB('admin');
const password = process.env.MONGODB_ROOT_PASSWORD;
let authenticated = false;
try { authenticated = admin.auth('root', password).ok === 1; } catch (_) {}
if (authenticated) {
  const hosts = [0, 1, 2].map(i =>
    `rocketchat-mongodb-${i}.rocketchat-mongodb.${process.env.POD_NAMESPACE}.svc.cluster.local:27017`
  ).join(',');
  const connection = new Mongo(`mongodb://${hosts}/?replicaSet=rs0`);
  admin = connection.getDB('admin');
  if (admin.auth('root', password).ok !== 1) throw new Error('Bootstrap authentication failed');
}
if (!admin.hello().setName) {
  rs.initiate({
    _id: 'rs0',
    members: [0, 1, 2].map(i => ({
      _id: i,
      host: `rocketchat-mongodb-${i}.rocketchat-mongodb.${process.env.POD_NAMESPACE}.svc.cluster.local:27017`,
      priority: i === 0 ? 2 : 1,
    })),
  });
}
let ready = false;
for (let attempt = 0; attempt < 120; attempt++) {
  if (admin.hello().isWritablePrimary) { ready = true; break; }
  sleep(1000);
}
if (!ready) throw new Error('Primary election timed out');
if (!authenticated) {
  admin.createUser({user: 'root', pwd: password, roles: ['root']});
  if (admin.auth('root', password).ok !== 1) throw new Error('Bootstrap authentication failed');
}
const chat = admin.getSiblingDB('rocketchat');
if (!chat.getUser('rocketchat')) {
  chat.createUser({
    user: 'rocketchat', pwd: process.env.MONGODB_PASSWORD,
    roles: [{role: 'readWrite', db: 'rocketchat'}, {role: 'dbAdmin', db: 'rocketchat'}],
  });
}
