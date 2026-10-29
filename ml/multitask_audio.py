"""Small shared audio network: radius, |x|, |y| and three radial regions.

Uses train-only PCA and a shared 8-unit tanh layer. The six outputs are three
continuous coordinates (scaled by 12 cm) and three region logits. No framework,
network connection or firmware changes are required.
"""
import numpy as np


def region_labels(distance):
    return np.where(distance <= 4, 0, np.where(distance <= 8, 1, 2))


class MultiTaskAudio:
    def __init__(self, epochs=200, decay=.01, components=16, seed=19):
        self.epochs, self.decay, self.components, self.seed = epochs, decay, components, seed

    @staticmethod
    def objective(parameters, z, targets, regions, class_weights, decay):
        w1,b1,w2,b2=parameters
        h=np.tanh(z@w1+b1)
        out=h@w2+b2
        n=len(z)
        residual=out[:,:3]-targets
        # Huber loss, with a 1.5 cm transition in the normalized coordinates.
        delta=.125;absolute=np.abs(residual);head_weights=np.array([4.,1.,1.])
        huber=np.where(absolute<=delta,.5*residual**2,delta*(absolute-.5*delta))
        loss=float(np.sum(huber*head_weights)/n)
        logits=out[:,3:]-out[:,3:].max(axis=1,keepdims=True)
        probs=np.exp(logits);probs/=probs.sum(axis=1,keepdims=True)
        weights=class_weights[regions]
        ce_scale=.3
        loss-=float(ce_scale*np.sum(weights*np.log(np.maximum(probs[np.arange(n),regions],1e-12)))/n)
        loss+=float(.5*decay*(np.sum(w1*w1)+np.sum(w2*w2)))
        gradient=np.zeros_like(out)
        gradient[:,:3]=np.clip(residual,-delta,delta)*head_weights/n
        one_hot=np.eye(3)[regions]
        gradient[:,3:]=ce_scale*(probs-one_hot)*weights[:,None]/n
        g2=h.T@gradient+decay*w2;gb2=gradient.sum(0)
        gh=(gradient@w2.T)*(1-h*h)
        g1=z.T@gh+decay*w1;gb1=gh.sum(0)
        return loss,[g1,gb1,g2,gb2]

    def fit(self,x,distance,xy):
        x=np.asarray(x,dtype=float)
        self.mean,self.std=x.mean(0),x.std(0)+1e-6
        z=(x-self.mean)/self.std
        _,_,vh=np.linalg.svd(z,full_matrices=False)
        self.projection=vh[:min(self.components,len(vh))].T
        latent=z@self.projection
        self.latent_std=latent.std(0)+1e-6
        latent/=self.latent_std
        targets=np.column_stack([distance,np.abs(xy)])/12
        regions=region_labels(distance)
        counts=np.bincount(regions,minlength=3)
        class_weights=len(distance)/(3*np.maximum(counts,1))
        rng=np.random.default_rng(self.seed)
        self.parameters=[rng.normal(size=(latent.shape[1],8))/np.sqrt(latent.shape[1]),
                         np.zeros(8),rng.normal(size=(8,6))*.05,
                         np.r_[targets.mean(0),np.zeros(3)]]
        moments=[np.zeros_like(p) for p in self.parameters]
        variances=[np.zeros_like(p) for p in self.parameters]
        self.loss_history=[]
        for step in range(1,self.epochs+1):
            loss,gradients=self.objective(self.parameters,latent,targets,regions,class_weights,self.decay)
            if not np.isfinite(loss):raise ValueError('Non-finite multi-task training loss')
            self.loss_history.append(loss)
            rate=.006*(.25+.75*.5*(1+np.cos(np.pi*(step-1)/self.epochs)))
            for i,g in enumerate(gradients):
                moments[i]=.9*moments[i]+.1*g;variances[i]=.999*variances[i]+.001*g*g
                self.parameters[i]-=rate*(moments[i]/(1-.9**step))/(np.sqrt(variances[i]/(1-.999**step))+1e-8)
        return self

    def predict(self,x):
        latent=(((x-self.mean)/self.std)@self.projection)/self.latent_std
        w1,b1,w2,b2=self.parameters
        out=np.tanh(latent@w1+b1)@w2+b2
        logits=out[:,3:]-out[:,3:].max(axis=1,keepdims=True)
        p=np.exp(logits);p/=p.sum(axis=1,keepdims=True)
        return {'distance':np.maximum(out[:,0]*12,0),
                'abs_xy':np.maximum(out[:,1:3]*12,0),
                'region_probability':p,'sweet':np.argmax(p,axis=1)==0}
